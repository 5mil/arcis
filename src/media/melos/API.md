# Melos API routes

Wired handlers in `api.zig`:

| Method | Path                      | Purpose                          |
|--------|---------------------------|----------------------------------|
| POST   | /api/melos/generate       | text/attributes → SymbolicPiece  |
| POST   | /api/melos/analyze        | piece → summary                   |
| POST   | /api/melos/live/step      | next live bar of notes           |
| POST   | /api/melos/live/modulate  | crowd prompt → attribute update   |

## GLM modulation path
`live.modulateFromPrompt` is the hook. Replace the keyword stub with:

```zig
// inside modulateFromPrompt
const plan = try glm_planner.plan(crowd_prompt);
// parse plan into updated MusicAttributes
```

or call the registered `melos.modulate` tool via the agent.

## MIDI output
`midi_out.zig` → `toMidiFile()` produces a multi-track Type-1 MIDI buffer
from any SymbolicPiece. Serve it as `application/octet-stream` for download
or stream it to an external synth.

## Registration
Add the four handlers to Arcis’s HTTP router (see comments in `api.zig`).

GUI already calls these endpoints.
