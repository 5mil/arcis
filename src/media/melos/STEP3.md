# Melos Step 3 — Symbolic Understanding Foundation

## Goal
Give Melos the ability to analyze and index symbolic music so agents can search, condition, and reason about pieces before generation.

## What landed
- `symbolic.zig`
  - `SymbolicSummary` — compact analytic view (key, tempo, density, pitch stats, roles)
  - `summarize()` — rule-based analysis of a `SymbolicPiece`
  - `RetrievalKey` — placeholder for later embedding-based search

## How it fits
1. Agent receives a piece or MIDI.
2. Calls `summarize()` → structured attributes.
3. Uses the summary (and later embeddings) for retrieval or to condition `melos.generate`.

## Next increments inside step 3
- Symbolic encoder interface (even a simple pitch/rhythm histogram first).
- In-memory index over `RetrievalKey`.
- Optional alignment with text descriptions (CLaMP-style).

## Relation to GLM planner
The GLM-5.3-Flash planner (step 2 + wiring) can call these analysis functions via the `melos.analyze` tool, then decide on generation or editing steps.

See `symbolic.zig` for the implementation.
