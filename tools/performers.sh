#!/bin/sh
# Admin CLI for Melos performer accounts. Run on the VPS as goji.
# Passwords are written only to the mode-600 credentials file; never printed.
set -eu
ROOT="${ARCIS_ENGINE_ROOT:-/opt/arcis/engine}"
BIN="${ARCIS_ENGINE_BIN:-$ROOT/bin/arcis}"
export MELOS_PERFORMERS_FILE="${MELOS_PERFORMERS_FILE:-$ROOT/secrets/performers.hashes}"
export MELOS_PERFORMERS_INITIAL="${MELOS_PERFORMERS_INITIAL:-$ROOT/secrets/performers-initial.txt}"
if [ ! -x "$BIN" ]; then
  echo "performers.sh: engine binary not found or not executable: $BIN" >&2
  exit 1
fi
exec "$BIN" performers "$@"
