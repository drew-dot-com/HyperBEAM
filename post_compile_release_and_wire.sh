#!/usr/bin/env bash
set -euo pipefail
LOG_DIR=/home/ubuntu/drewgle_session_logs
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/post_compile_release_and_wire_$(date -u +%Y%m%d_%H%M%SZ).log"
{
  echo "[start] $(date -Is) waiting for compile to finish"
  # Wait until no rebar3 compile is running
  for i in $(seq 1 720); do
    if pgrep -f "/usr/local/bin/rebar3 -B -sbtu.*compile" >/dev/null 2>&1; then
      sleep 10
    else
      break
    fi
  done
  if pgrep -f "/usr/local/bin/rebar3 -B -sbtu.*compile" >/dev/null 2>&1; then
    echo "[timeout] compile still running after wait window"; exit 1
  fi
  echo "[compile] finished; running release"
  cd /home/ubuntu/HyperBEAM
  /usr/bin/time -f "[time release] %E %MKB" rebar3 release || true
  echo "[hb] restart"
  sudo systemctl daemon-reload || true
  sudo systemctl restart hyperbeam || true
  sleep 3
  systemctl is-active hyperbeam || true
  systemctl show -p MainPID --value hyperbeam || true
  echo "[meta] snippet"
  curl -sS -m 10 -H "Accept: application/json" http://127.0.0.1:8734/~meta@1.0/info | sed -n "1,60p" || true
  echo "[wire] signed Set* + probe"
  export HB_URL=http://127.0.0.1:8734
  export WALLET=/home/ubuntu/drewgle/wallet.json
  FRONT=ZmCdT-vz4LNHd9Tmi-BnKk7J4BKZVwvJ4P6CM7p02SY
  COORD=30VKkbcTmh8vrJsY6nGB56S2r9VPDx68SoSRBJwCE7w
  PAY=nbxTP6XDB038NJVTgtRHpNritmWfDcKSOaiPNtOmSzo
  HB_URL=$HB_URL WALLET=$WALLET TARGET=$FRONT ACTION=SetCoordinator KV=Coordinator:$COORD node /home/ubuntu/drewgle/hbops/send_message_json_signed.mjs || true
  HB_URL=$HB_URL WALLET=$WALLET TARGET=$FRONT ACTION=SetPaymentRouter KV=PaymentRouter:$PAY node /home/ubuntu/drewgle/hbops/send_message_json_signed.mjs || true
  HB_URL=$HB_URL WALLET=$WALLET PID=$FRONT node /home/ubuntu/drewgle/hbops/signed_get_now.mjs || true
  echo "[session] capture"
  /home/ubuntu/drewgle/scripts/collect-status.sh || true
  echo "[done] $(date -Is)"
} | tee "$LOG"
