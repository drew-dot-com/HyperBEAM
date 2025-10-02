#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
TARGET_LIB="$ROOT_DIR/lib"
if [ -d "$TARGET_LIB" ]; then
  echo "Removing vendored lib/ directory: $TARGET_LIB"
  rm -rf "$TARGET_LIB"
fi
mkdir -p "$TARGET_LIB"
if [ -d "$ROOT_DIR/_build" ]; then
  echo "Removing _build directory: $ROOT_DIR/_build"
  rm -rf "$ROOT_DIR/_build"
fi
