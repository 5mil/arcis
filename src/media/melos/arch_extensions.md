# Melos / Arcis Architecture Extensions for GLM-5.3-Flash

GLM-5.3-Flash (320B-A18B) uses a hybrid design that Arcis’s current `src/infer/` transformer does not yet fully support. This sketch outlines the minimal extensions needed for native loading and inference.

## Key architectural differences

| Feature              | Arcis today                  | GLM-5.3-Flash                          |
|----------------------|------------------------------|----------------------------------------|
| Attention            | Standard multi-head + RoPE   | Hybrid: 34 linear + 11 sparse layers  |
| Experts              | Dense                        | MoE (288 routed + 1 shared, top-8)    |
| Connections          | Residual                     | Manifold-Constrained Hyper-Connections (mHC) |
| Context              | Model-dependent              | 1M tokens (efficient via hybrid)      |
| Vision               | None                         | Native multimodal (optional)          |

## Proposed extension points

### 1. Loader (`src/infer/loader.zig` / `gguf.zig`)
- Detect hybrid architecture from GGUF metadata.
- Load separate linear-attention and sparse-attention weight sets.
- Load MoE expert tensors and routing weights.

### 2. Transformer forward (`src/infer/transformer.zig`)
- Add a layer-type enum: `.dense`, `.linear_attn`, `.sparse_attn`, `.moe`.
- Implement (or stub) linear attention (stateful, no full KV for those layers).
- Implement sparse attention with its indexer.
- Add MoE routing + expert dispatch (top-k).
- Optional mHC residual path.

### 3. KV cache (`src/infer/kvcache.zig`)
- Hybrid cache: full KV only for sparse layers; compact state for linear layers.
- 1M-context friendly sizing.

### 4. Melos planner integration
- Once the above land, `GlmPlanner` in `glm_planner.zig` works unchanged.
- CLI flag `--melos-model` (see `config.zig`) selects the GGUF.

## Temporary bridge (no architecture changes)
Until native support exists, Melos can call an external llama.cpp / Unsloth server:
- Start `llama-server` with the Unsloth GGUF.
- Melos tools issue HTTP requests to `/v1/chat/completions`.
- Keeps the same `GlmPlanner.plan()` interface.

## Priority order
1. CLI/config flag (done — see `config.zig`).
2. External bridge (fastest path to usable Melos agent).
3. Native hybrid attention + MoE kernels.
4. mHC and full 1M efficiency.

This keeps Melos moving while the inference core catches up.
