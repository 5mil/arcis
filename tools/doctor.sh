#!/bin/sh
set -u
cd "$(dirname "$0")/.."
ok=0; fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "OK  $1"; ok=$((ok+1)); else echo "NO  $1"; fail=$((fail+1)); fi; }
echo "== Arcis doctor =="
check "binary" "test -x zig-out/bin/arcis"
check "listen 9090" "ss -tln | grep -q ':9090'"
check "health JSON" "curl -sS -m 3 http://127.0.0.1:9090/health | grep -q status"
check "house GGUF" "test -f models/gguf/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
check "library dir" "test -d data/library"
echo "ok=$ok fail=$fail"
[ "$fail" -eq 0 ]
