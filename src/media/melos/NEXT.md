# Melos — Next Increments Summary

## 1. Symbolic encoder + index (`encoder.zig`)
- `FeatureVector` (pitch-class histogram + density + roles)
- `encode()`
- `SymbolicIndex` with linear nearest-neighbor search
- Ready for agent retrieval (“find similar pieces”)

## 2. External GLM bridge (`bridge.zig`)
- `GlmBridge` that targets an OpenAI-compatible llama.cpp / Unsloth server
- Lets Melos use GLM-5.3-Flash today without waiting for native hybrid attention
- Start server: `llama-server -m path/to/gguf --port 8080`

## 3. Step 4 text-to-symbolic (`generate.zig`)
- Clean request/result types
- Working `generateStub()` for end-to-end agent testing
- Drop-in replacement point for a real model later

All three are additive and do not break existing Melos types or the agent tool registry.
