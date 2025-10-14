#!/usr/bin/env bash
set -euo pipefail
# Simple shim to keep a heartbeat; relies on running local-cu at 6363
while true; do
  curl -fsS http://127.0.0.1:6363/status >/dev/null 2>&1 || true
  sleep 5
done
