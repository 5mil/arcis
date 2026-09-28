#!/bin/sh
# Pull skip-ahead GGUF into models/gguf/ for Arcis --model
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=$ROOT/models/gguf
mkdir -p "$DEST"
ID=${1:-r1-1.5b-q4}

url_r1="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
file_r1="DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
url_l32="https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"
file_l32="Llama-3.2-1B-Instruct-Q4_K_M.gguf"

pull() {
  u=$1; f=$2
  if [ -f "$DEST/$f" ]; then echo "have $f"; return; fi
  echo "GET $f"
  wget -c -O "$DEST/$f.part" "$u"
  mv "$DEST/$f.part" "$DEST/$f"
}

case $ID in
  r1-1.5b-q4|r1|default) pull "$url_r1" "$file_r1" ;;
  llama32-1b-q4|llama) pull "$url_l32" "$file_l32" ;;
  both) pull "$url_r1" "$file_r1"; pull "$url_l32" "$file_l32" ;;
  *) echo "usage: $0 r1-1.5b-q4|llama32-1b-q4|both"; exit 1 ;;
esac
ls -lh "$DEST"
echo "Run: ./zig-out/bin/arcis --model models/gguf/$file_r1 --port 9090"
echo "Note: current Zig loader is F16/F32-only; Q4 needs llama.cpp until quant lands."
