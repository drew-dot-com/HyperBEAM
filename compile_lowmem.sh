#!/usr/bin/env bash
set -euo pipefail
cd /home/ubuntu/HyperBEAM
export MAKEFLAGS=-j1
export ERL_FLAGS="+S 2:2"
/usr/bin/time -f "[compile-lowmem] %E %MKB" rebar3 compile
