#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
chmod +x tools/pull_gguf.sh
./tools/pull_gguf.sh r1-1.5b-q4
zig build
exec ./zig-out/bin/arcis --tier forma --port 9090 \
  --model models/gguf/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf
