#!/usr/bin/env bash
set -euo pipefail
LOG=/home/ubuntu/HyperBEAM/resume_run_$(date -u +%Y%m%d_%H%M%SZ).log
: > "$LOG"
exec >> "$LOG" 2>&1

echo "[start] $(date -Is)"; cd /home/ubuntu/HyperBEAM
# Ensure HB is stopped during compile
sudo systemctl stop hyperbeam || true
free -h

# Compile + release
/usr/bin/time -f "[time compile] %E %MKB" rebar3 compile
/usr/bin/time -f "[time release] %E %MKB" rebar3 release

# Restart HB
sudo systemctl daemon-reload || true
sudo systemctl restart hyperbeam
sleep 3
systemctl is-active hyperbeam && systemctl show -p MainPID --value hyperbeam || true

# Meta quick check
curl -sS -m 6 -H "Accept: application/json" http://127.0.0.1:8734/~meta@1.0/info | sed -n "1,80p" || true

# Signed wiring
export HB_URL=http://127.0.0.1:8734
export WALLET=/home/ubuntu/drewgle/wallet.json
FRONT=ZmCdT-vz4LNHd9Tmi-BnKk7J4BKZVwvJ4P6CM7p02SY
COORD=30VKkbcTmh8vrJsY6nGB56S2r9VPDx68SoSRBJwCE7w
PAY=nbxTP6XDB038NJVTgtRHpNritmWfDcKSOaiPNtOmSzo

echo "[wire] SetCoordinator"
HB_URL=$HB_URL WALLET=$WALLET TARGET=$FRONT ACTION=SetCoordinator KV=Coordinator:$COORD node /home/ubuntu/drewgle/hbops/send_message_json_signed.mjs || true

echo "[wire] SetPaymentRouter"
HB_URL=$HB_URL WALLET=$WALLET TARGET=$FRONT ACTION=SetPaymentRouter KV=PaymentRouter:$PAY node /home/ubuntu/drewgle/hbops/send_message_json_signed.mjs || true

echo "[probe] signed_get_now"
HB_URL=$HB_URL WALLET=$WALLET PID=$FRONT node /home/ubuntu/drewgle/hbops/signed_get_now.mjs || true

# Capture status
/home/ubuntu/drewgle/scripts/collect-status.sh || true

echo "[done] $(date -Is)"
