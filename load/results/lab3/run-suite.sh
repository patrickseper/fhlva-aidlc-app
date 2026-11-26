#!/usr/bin/env bash
# Runs the full Lab 3 test suite against the local Compose stack, one run after another.
cd /workspaces/fhlva-aidlc-app
OUT=load/results/lab3
mkdir -p "$OUT"

run() {
  local label=$1; shift
  local start=$(date +%H:%M:%S)
  env "$@" ./load/run-local.sh > "$OUT/$label.log" 2>&1
  local rc=$?
  echo "$label start=$start end=$(date +%H:%M:%S) EXIT=$rc"
}

# wait until /statistics responds again (service warm after restart)
for i in $(seq 1 40); do
  curl -s -o /dev/null -w '%{http_code}' localhost:8080/statistics/global | grep -qE '200|401|403' && break
  [[ $i == 40 ]] && { echo "ABORT: statistics not reachable via nginx after 2 min"; exit 1; }
  sleep 3
done
sleep 10

run 01-smoke          PROFILE=smoke
run 02-baseline5      PROFILE=baseline RATE=5 DURATION=2m
run 03-gate5          PROFILE=gate RATE=5
run 04-spike10x5      PROFILE=spike RATE=10 SPIKE_FACTOR=5 DURATION=2m
run 05-spike40x5      PROFILE=spike RATE=40 SPIKE_FACTOR=5 DURATION=2m USERS=200
run 06-baseline200    PROFILE=baseline RATE=200 DURATION=2m USERS=200
run 07-gate200        PROFILE=gate RATE=200 USERS=200
run 08-newcomers1x1   PROFILE=newcomers RATE=1 SPIKE_FACTOR=1 DURATION=1m
run 09-newcomers2x5   PROFILE=newcomers RATE=2 SPIKE_FACTOR=5 DURATION=2m
podman logs --since 10m fhlva-aidlc-app_statistics-service_1 2>&1 \
  | grep -o '"message":"[^"]\{0,90\}' | sed 's/[0-9a-f-]\{36\}/<uuid>/g; s/[0-9]\{3,\}ms/Nms/g' \
  | sort | uniq -c | sort -rn | head -8 > "$OUT/09-statistics-log-summary.txt"
run 10-smoke-direct   PROFILE=smoke
sleep 180
run 11-smoke-recovered PROFILE=smoke
echo SUITE DONE
