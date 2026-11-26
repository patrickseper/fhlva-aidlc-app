# Lab Report 3

**Team-Mitglieder:** Dominik Rauscher, Lukas Böhm-Gundacker, Patrick Seper

## Ziel

Lasttests mit k6 gegen Beer Tracker: SLOs aus Lab 2 als k6-Thresholds umsetzen, die Lastprofile `smoke`, `baseline`, `spike`, `newcomers` und `gate` ausführen und versuchen, die SLOs zu brechen.

## Durchgeführte Schritte

1. Compose-Stack gebaut und gestartet:
   ```bash
   podman compose up -d --build
   ```
2. Erster Smoke-Test mit den Platzhalter-Thresholds, um die Journey zu prüfen:
   ```bash
   PROFILE=smoke ./load/run-local.sh
   ```
3. `load/slo.json` mit unseren SLOs aus Lab 2 befüllt (siehe unten).
4. Alle Profile nacheinander in einer Test-Suite ausgeführt. Die Reihenfolge ist so gewählt, dass der Überlast-Test (`newcomers`) zuletzt läuft und die anderen Messungen nicht verfälscht.
5. Ursachenanalyse anhand der Logs des `statistics-service` und des Quellcodes.

## SLOs als k6-Thresholds (`load/slo.json`)

```json
{
  "errorRate": 0.005,
  "steps": {
    "statistics_me": { "p95": 300, "p99": 1000 },
    "statistics_trend": { "p95": 300, "p99": 1000 },
    "statistics_global": { "p95": 300, "p99": 1000 },
    "tracking_list": { "p95": 1000 },
    "tracking_create": { "p95": 1000 },
    "notifications_list": { "p95": 1000 }
  }
}
```

| SLO aus Lab 2                                              | Umsetzung in k6                                      | Abweichung                                                                                                                                      |
| ---------------------------------------------------------- | ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 – Verfügbarkeit ≥ 99,5 % (kein 5xx auf `/statistics/**`) | `errorRate: 0.005` → `http_req_failed rate<0.005`    | k6 zählt **alle** fehlgeschlagenen Requests (auch 4xx, Timeouts > 10 s) über **alle** Services. Der Threshold ist damit strenger als unser SLI. |
| 2 – Latenz ≥ 95 % < 300 ms, ≥ 99 % < 1 s                   | `p95: 300`, `p99: 1000` auf den drei Statistik-Steps | Entspricht dem SLO direkt.                                                                                                                      |
| 3 – Datenaktualität (`cached_at` < 30 min)                 | **nicht abbildbar**                                  | k6 misst nur Requests. Ein veralteter Cache liefert weiterhin schnell `200 OK`.                                                                 |

Für die übrigen Steps haben wir in Lab 2 keine SLOs definiert. Sie behalten den Platzhalter von 1 s, damit sie in der Zusammenfassung erscheinen.

## Ergebnisse

Ein „Visit“ ist ein kompletter Besuch eines bestehenden Users (5–6 Requests). p95/p99 bedeutet: 95 % bzw. 99 % der Requests waren schneller als dieser Wert. Exit 0 = alle Thresholds eingehalten, Exit 99 = mindestens einer verletzt.

| #   | Profil      | Last                    | Exit   | Fehlerrate             | p95 / p99 `statistics_me`                    | Ergebnis                     |
| --- | ----------- | ----------------------- | ------ | ---------------------- | -------------------------------------------- | ---------------------------- |
| 01  | `smoke`     | 1 VU, 30 s              | 0      | 0 %                    | 6,8 / 6,9 ms                                 | ✅                           |
| 02  | `baseline`  | 5 Visits/s, 2 min       | 0      | 0 % (0/3253)           | 4,5 / 5,7 ms                                 | ✅                           |
| 03  | `gate`      | 5 Visits/s, 1 min       | 0      | 0 % (0/1678)           | 3,2 / 3,4 ms                                 | ✅                           |
| 04  | `spike`     | 10 → 50 Visits/s        | 0      | 0 % (0/47 831)         | 2,4 / 3,1 ms                                 | ✅                           |
| 05  | `spike`     | 40 → **200** Visits/s   | 0      | 0 % (0/191 766)        | 7,6 / 45,3 ms                                | ✅                           |
| 06  | `baseline`  | **200** Visits/s, 2 min | 0      | 0 % (0/128 070)        | 49,1 / 129,8 ms                              | ✅                           |
| 07  | `gate`      | **200** Visits/s, 1 min | 0      | 0 % (0/64 449)         | 2,6 / 3,4 ms                                 | ✅                           |
| 08  | `newcomers` | 1 neuer User/s          | 0      | 0 % (0/416)            | `statistics_me_first`: 915 ms / 1,13 s       | ✅ formal, aber p99 über 1 s |
| 09  | `newcomers` | 2 → **10** neue User/s  | **99** | **24,5 %** (1407/5752) | `statistics_me_first`: 10 s / 10 s (Timeout) | ❌                           |
| 10  | `smoke`     | direkt nach #09         | **99** | 3,0 % (7/233)          | 3,0 / 458,9 ms                               | ❌ noch nicht erholt         |
| 11  | `smoke`     | 3 min nach #10          | 0      | 0 %                    | 3,2 / 3,3 ms                                 | ✅ erholt                    |

### Zusammenfassung

- **Bestehende User sind kein Problem.** Auch bei 200 Visits/s (ca. 1.060 Requests/s, das Maximum des Load-Drivers) gab es keine Fehler. In #06 stieg p95 von `statistics_me` auf 49 ms, erlaubt sind 300 ms. #07 war bei gleicher Rate deutlich schneller, die Ursache haben wir nicht untersucht.
- **Viele neue User blockieren den `statistics-service`.** In #09 liefen 1407 von 1438 ersten Statistik-Aufrufen in das Timeout von 10 s. Registrierung, Login und Bier-Eintrag blieben schnell (p95 < 450 ms).
- **Das System erholt sich ohne Neustart.** Drei Minuten nach dem fehlgeschlagenen Smoke-Test (#10) war wieder alles grün (#11).
- Nicht gestartete Iterationen (`dropped_iterations`) gab es nur in #09 (91).

## Ursache des Ausfalls

Für neue User gibt es noch keine gespeicherten Statistiken. Der `statistics-service` berechnet sie daher, während der User wartet:

1. Jeder erste Aufruf belegt **zwei** der nur 10 Datenbank-Connections (eine in `getPersonalStats()`, eine zweite in `refreshUserStats()` wegen `REQUIRES_NEW`).
2. Währenddessen ruft er den `beer-tracking-service` rund **368-mal nacheinander** auf, davon 365-mal für die einzelnen Tage des letzten Jahres.
3. Bei vielen gleichzeitigen Aufrufen sind alle Connections belegt, und jeder wartet auf eine zweite, die nicht frei wird. Der Connection-Pool bricht erst nach 30 s ab, k6 hat schon nach 10 s aufgegeben.

Zusätzlich hat der `RestTemplate` keine Timeouts: Ein langsamer `beer-tracking-service` würde die Connections unbegrenzt blockieren.

**Fix-Vorschläge**:

1. Pro Request nur eine Connection verwenden (Berechnung außerhalb der Lese-Transaktion).
2. Die Tageswerte mit einem einzigen Aufruf holen statt mit 365.
3. Statistiken für neue User schon beim ersten Bier-Eintrag im Hintergrund berechnen.
4. Timeouts für den `RestTemplate` setzen.

Nur den Connection-Pool zu vergrößern, würde das Problem lediglich verschieben.

## Weitere Probleme und Maßnahmen

| Problem                                                               | Erklärung                                                                                                                                    | Maßnahme                                                                                                 |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Erster Statistik-Aufruf ist schon bei 1 neuen User/s zu langsam (#08) | p99 = 1,13 s statt < 1 s. Der Test besteht trotzdem, weil `script.js` für `statistics_me_first` nur einen Schein-Threshold (`max>=0`) setzt. | Echten Threshold in `slo.json` ergänzen **und** `script.js` anpassen, damit er nicht überschrieben wird. |
| Smoke nach der Überlast schlägt fehl (#10)                            | Alle 7 Fehler waren Timeouts in der Testvorbereitung (`setup()`), nicht in der gemessenen Journey. Der Threshold zählt sie trotzdem mit.     | Vorschlag: nur die gemessenen Requests bewerten (eigener Tag, z. B. `phase:load`).                       |
| Fehlerrate in k6 ist strenger als unser SLI                           | k6 zählt alle Services, auch 4xx und Timeouts.                                                                                               | Bewusst so belassen.                                                                                     |

## Reproduktion

```shell
 PROFILE=smoke ./load/run-local.sh
 PROFILE=baseline RATE=5 DURATION=2m ./load/run-local.sh
 PROFILE=gate RATE=5 ./load/run-local.sh
 PROFILE=spike RATE=10 SPIKE_FACTOR=5 DURATION=2m ./load/run-local.sh
 PROFILE=spike RATE=40 SPIKE_FACTOR=5 DURATION=2m USERS=200 ./load/run-local.sh
 PROFILE=baseline RATE=200 DURATION=2m USERS=200 ./load/run-local.sh
 PROFILE=gate RATE=200 USERS=200 ./load/run-local.sh
 PROFILE=newcomers RATE=1 SPIKE_FACTOR=1 DURATION=1m ./load/run-local.sh
 PROFILE=newcomers RATE=2 SPIKE_FACTOR=5 DURATION=2m ./load/run-local.sh
 PROFILE=smoke ./load/run-local.sh
 sleep 180
 PROFILE=smoke ./load/run-local.sh
```
