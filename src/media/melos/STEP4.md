# Melos Step 4 — Text-to-Symbolic Generation

## Goal
Turn text or MusicAttributes into a SymbolicPiece (multi-track MIDI).
Inspired by MuseCoco and GETMusic.

## What landed
- `generate.zig`
  - `GenerateRequest` / `GenerateResult`
  - `generateStub()` — simple rule-based monophonic melody for testing the agent loop

## Integration path
1. Register `melos.generate` tool (already stubbed in `tools.zig`).
2. Tool handler parses JSON → `GenerateRequest`.
3. Calls `generateStub()` (or later a real model).
4. Returns serialized SymbolicPiece.

## Next
- Replace stub with a conditioned generator (attribute → pitch/rhythm patterns).
- Multi-track support (melody + bass + drums).
- Attach to GLM planner so the agent can decide when to call generate.

See `generate.zig` for the interface.
