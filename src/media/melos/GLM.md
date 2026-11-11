# Melos + GLM-5.3-Flash

## Status
GLM-5.3-Flash is wired as the preferred Melos planner backend via Arcis’s native GGUF `Session`.

## Recommended model
- **unsloth/GLM-5.3-Flash-GGUF** (MIT)
- Architecture: 320B total / 18B active, hybrid sparse + linear attention, MoE, 1M context
- Good quant starting points:
  - UD-IQ3_XXS (~120 GB) for 128 GB class machines
  - UD-Q4_K_XL (~200 GB) for higher quality
- Official weights: zai-org/GLM-5.3-Flash (FP8 ~328 GB)

## Current Arcis constraints
Arcis’s `src/infer/` transformer is a standard GGUF path (attention, RoPE, KV cache, sampler).
GLM-5.3-Flash uses a newer hybrid attention + MoE + mHC design. Full native speed therefore requires:
1. Extending the transformer / loader for hybrid linear+sparse attention and expert routing, or
2. Running an external llama.cpp / Unsloth server and calling it from the Melos tools (temporary bridge).

The interface in `glm_planner.zig` is ready for either path.

## How the Melos agent uses it
1. Load the GGUF into an Arcis `Session` (or bridge).
2. Construct `GlmPlanner` with the session.
3. The existing `Agent` / `Orchestrator` can call `planner.plan(...)` as the reasoning step before dispatching `melos.generate` / `melos.analyze`.

## Next practical steps
- Add a model config flag (e.g. `--melos-model path/to/glm-5.3-flash.gguf`).
- Implement or bridge the architecture-specific kernels.
- Replace tool stubs with real symbolic generation once the planner can reliably emit structured calls.

See `glm_planner.zig` for the concrete types.
