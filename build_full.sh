#!/usr/bin/env bash
set -euo pipefail
cd /home/ubuntu/HyperBEAM
export CC="ccache gcc"; export CXX="ccache g++"; export MAKEFLAGS=-j1; export ERL_FLAGS="+S 2:2"
LOG=/home/ubuntu/HyperBEAM/build_full.log
{
  echo "[start] $(date -Is)"
  rebar3 clean
  rebar3 update
  rebar3 deps
  REBAR_OFFLINE=1 rebar3 compile
  rebar3 release
  echo "[done] $(date -Is)"
} |& tee "$LOG"
