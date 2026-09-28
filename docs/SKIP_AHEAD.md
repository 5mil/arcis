# Skip-ahead weights (in Arcis, not Ollama)

Default house model is **DeepSeek-R1-Distill-Qwen-1.5B** Q4_K_M GGUF (~1.1 GB, Apache-2.0).
Base: https://huggingface.co/deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B
Quant: bartowski GGUF.

```bash
cd ~/arcis   # or clone https://github.com/5mil/arcis
chmod +x tools/pull_gguf.sh
./tools/pull_gguf.sh r1-1.5b-q4
./zig-out/bin/arcis --tier forma --port 9090 \
  --model models/gguf/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf
```

`models/gguf/` is gitignored. Catalog: `models/catalog.toml`.

## Honest loader gap

`src/main.zig` still says only F16/F32 GGUF run inside Zig Session. Q4 will `loadModel` fail and `/infer` stays 503.

Skip-ahead *inference* until quant works:

```bash
# llama.cpp server pointed at the same file Arcis just downloaded
./llama-server -m models/gguf/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf --port 9080
```

Arcis console (P0) should treat `localhost:9080` as backend A. That is how you jump the Zig kernel without going back to Ollama as the product.
