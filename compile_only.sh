#!/usr/bin/env bash
set -euo pipefail
cd /home/ubuntu/HyperBEAM
/usr/bin/time -f "[compile] %E %MKB" rebar3 compile
