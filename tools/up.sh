#!/bin/sh
# Ease of use: library + house GGUF + listen :9090
set -e
cd "$(dirname "$0")/.."
chmod +x tools/pull_gguf.sh tools/link_library.sh 2>/dev/null || true
./tools/link_library.sh || true
if [ ! -f models/gguf/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf ]; then
  ./tools/pull_gguf.sh r1-1.5b-q4 || true
fi
zig build
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
IP=${IP:-192.168.50.143}
echo ""
echo "Arcis  http://$IP:9090/"
echo "Desk   http://$IP:8787/"
echo ""
exec ./zig-out/bin/arcis --tier forma --port 9090
