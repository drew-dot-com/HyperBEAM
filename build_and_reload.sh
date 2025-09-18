#!/usr/bin/env bash
set -euo pipefail
cd /home/ubuntu/HyperBEAM
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[build] start $START on branch $(git rev-parse --abbrev-ref HEAD)" | tee build_status.log
/usr/bin/time -f "%E %MKB" rebar3 compile >> build_status.log 2>&1 || { echo "[build] FAILED" | tee -a build_status.log; exit 1; }
echo "[build] compiled, attempting restart" | tee -a build_status.log
if [ -x _build/default/rel/hb/bin/hb ]; then
  _build/default/rel/hb/bin/hb restart >> build_status.log 2>&1 || _build/default/rel/hb/bin/hb reboot >> build_status.log 2>&1 || true
  sleep 1
  _build/default/rel/hb/bin/hb ping >> build_status.log 2>&1 || true
fi
curl -fsS http://127.0.0.1:8734/~meta@1.0/info/address >> build_status.log 2>&1 || true
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[build] end $END" | tee -a build_status.log
