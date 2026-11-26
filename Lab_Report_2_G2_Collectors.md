# Lab Report 2

**Team-Mitglieder:** Dominik Rauscher, Lukas Böhm-Gundacker, Patrick Seper

## Azure AKS Deployment

### Durchgeführte Schritte

1. Resource Group und Log Analytics Workspace angelegt:
   ```bash
   az group create --name fhooe-aidlc-dev-rg --location germanywestcentral
   az monitor log-analytics workspace create --resource-group fhooe-aidlc-dev-rg \
     --workspace-name fhooe-aidlc-dev-law --location germanywestcentral
   ```
2. Resource Provider `Microsoft.Storage` registriert:
   ```bash
   az provider register --namespace Microsoft.Storage --wait
   ```
3. Storage für den Terraform Remote State angelegt:
   ```bash
   scripts/bootstrap-tf-state.sh --resource-group fhooe-aidlc-tfstate-rg \
     --storage-account fhooeaidlctfbsr --container tfstate --location germanywestcentral
   ```
4. Platzhalter in den Stage-Dateien gesetzt:
   - `infra/terraform/stages/dev/main.tf`: `subscription_id` = ID der Subscription
   - `infra/terraform/stages/dev/backend.tf`: `storage_account_name = "fhooeaidlctfbsr"`
5. Infrastruktur mit Terraform provisioniert:
   ```bash
   cd infra/terraform/stages/dev
   terraform init
   terraform plan -out=tfplan
   terraform apply tfplan
   ```
   Der Plan umfasste 15 Ressourcen: VNet mit Subnetzen, Application Gateway, ACR, AKS und Role Assignments. Netzwerk, Application Gateway und die Managed Identity wurden angelegt. ACR und AKS schlugen fehl, das Deployment wurde abgebrochen.

### Probleme und Lösungen

| Problem                                                                                                                        | Lösung                                                                                      |
| ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| Resource Provider `Microsoft.Storage` war nicht registriert, wird aber für den Terraform-State benötigt                        | Manuell registriert mit `az provider register --namespace Microsoft.Storage --wait`         |
| `terraform apply`: VM-Größe `Standard_D4s_v3` ist in der Subscription in `germanywestcentral` nicht erlaubt (`400 BadRequest`) | Das Deployment wurde an dieser Stelle abgebrochen. Die Anwendung läuft daher nicht auf AKS. |

## SLIs & SLOs – `statistics-service`

| #   | SLI                                                                                                                       | SLO (28 Tage rollierend)      |
| --- | ------------------------------------------------------------------------------------------------------------------------- | ----------------------------- |
| 1   | **Verfügbarkeit:** Anteil der Requests auf `/statistics/**` ohne 5xx-Antwort                                              | ≥ 99,5 %                      |
| 2   | **Latenz:** Anteil erfolgreicher Requests unter 300 ms bzw. unter 1 s                                                     | ≥ 95 % < 300 ms, ≥ 99 % < 1 s |
| 3   | **Datenaktualität:** Anteil der Minuten, in denen die älteste `cached_at` in `personal_stats_cache` jünger als 30 min ist | ≥ 99 %                        |

**Begründung**

1. **Verfügbarkeit:** Statistiken sind ein Nebenfeature. 99,5 % (≈ 3,4 h Ausfall pro 28 Tage) sind mit einer einzelnen Datenbank realistisch. Hinweis: Im Tenant wurde uns nur erlaubt eine ganze Zahl einzugeben (die Zahl nach dem Komma wurde ignoriert), daher haben wir dort 99% hinterlegt.
2. **Latenz:** Der Normalfall ist ein Cache-Read und soll unter 300 ms bleiben. Bei einem Cache-Miss wird das `beer-tracking-service` synchron aufgerufen. Die 1-s-Grenze begrenzt diesen langsameren Pfad.
3. **Datenaktualität:** Der Cache wird alle 15 min aktualisiert. Schlägt der Refresh fehl, liefert das Service weiter `200 OK` mit veralteten Daten. SLI 1 und 2 erkennen diesen Fall nicht. 30 min entsprechen 2 Refresh-Zyklen und tolerieren einen einzelnen fehlgeschlagenen Lauf.