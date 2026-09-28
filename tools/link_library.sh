#!/bin/sh
# Point Arcis data/library at MagiMDM OER if present.
set -e
cd "$(dirname "$0")/.."
mkdir -p data/library
SRC=$HOME/magimdm/data/library
if [ -d "$SRC" ]; then
  cp -n "$SRC"/*.txt data/library/ 2>/dev/null || true
  echo "copied from $SRC"
else
  echo "no $SRC — run MagiMDM tools/oer_fetch.sh core first"
fi
ls -la data/library || true
