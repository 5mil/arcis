# Melos Step 2 — Orchestration Layer

Melos tools are designed to drop straight into Arcis’s existing agent stack:

- `src/agents/tool.zig` → `ToolRegistry`
- `src/agents/orchestrator.zig` → `Agent` + `Orchestrator`
- `src/agents/planner.zig` → ReAct-style planning

## How to use

1. Call `registerMelosTools(&registry)` during session or agent init.
2. Create an `AgentRole` (or use the provided `melos_agent_role` constants).
3. Run multi-step music tasks via `agent.run(...)` or `orchestrator.dispatch(...)`.

## Current tools (stubs)

| Name            | Purpose                                      | Status   |
|-----------------|----------------------------------------------|----------|
| melos.generate  | text/attributes → SymbolicPiece              | stub     |
| melos.analyze   | SymbolicPiece → attributes / description     | stub     |
| melos.echo      | registration test                            | working  |

Later steps will replace the stubs with real generators, analyzers, and media calls (stems, TTS, etc.).

See `tools.zig` for the implementation.
