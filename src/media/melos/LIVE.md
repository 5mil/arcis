# Melos Live Performance Mode

## Overview
Live streaming / performance mode that sits on top of the existing Melos architecture:

- SymbolicPiece + MusicAttributes (step 1)
- Agent tools + GLM planner (step 2 + wiring)
- Symbolic analysis / index (step 3)
- Text-to-symbolic generation (step 4)
- External bridge or native Session for the AI

## Features
- **Live tab** in the GUI: continuous bar-by-bar generation
- **Piano roll** that updates in real time
- **Crowd prompts**: audience can type mood/tone requests
- **AI tone modulation**: crowd text is interpreted (via Melos agent / GLM) into updated attributes (emotion, tempo, density, etc.) that immediately affect the next bars

## Backend contract
- `POST /api/melos/live/step` → next short bar of MidiNotes
- `POST /api/melos/live/modulate` → interpret crowd prompt → new attributes

See `live.zig` for the Zig types and stubs. Replace the keyword stub with a real `GlmPlanner` or `melos.modulate` tool call when ready.

## GUI
The updated `gui/index.html` includes Studio and Live tabs. Live mode polls the step endpoint and sends crowd prompts to the modulate endpoint.

## Next
- WebSocket push instead of polling for lower latency
- Multi-track live (melody + bass + drums)
- MIDI output to external synths / DAW
- Persistent crowd session with voting or aggregated prompts
