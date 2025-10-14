#!/usr/bin/env bash
set -euo pipefail
cd /home/ubuntu/HyperBEAM
export MAKEFLAGS=-j6
export ERL_FLAGS="+S 8:8"
LOG=build_staged.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "[staged] $(date -u +%FT%TZ) start"
/usr/bin/time -f "[update] %E %MKB" rebar3 update
/usr/bin/time -f "[deps] %E %MKB"   rebar3 deps
/usr/bin/time -f "[compile] %E %MKB" env REBAR_OFFLINE=1 rebar3 compile
/usr/bin/time -f "[release] %E %MKB" rebar3 release
echo "[staged] $(date -u +%FT%TZ) done"
