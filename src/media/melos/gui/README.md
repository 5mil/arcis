# Melos GUI

Simple, dark, user-friendly web interface for the Melos music module.

## Features
- Prompt + attribute controls (key, tempo, bars, emotion)
- Generate button that calls `/api/melos/generate`
- Live piano-roll visualization of the returned MIDI notes
- Analyze button for the last generated piece
- Responsive layout

## How to use
1. Serve this folder from Arcis (or any static server) on the same origin as the API.
2. Ensure Arcis exposes:
   - `POST /api/melos/generate` → returns `{ piece: SymbolicPiece, ... }`
   - `POST /api/melos/analyze` → returns analysis / summary
3. Open `index.html` in a browser.

The GUI is pure HTML/CSS/JS — no build step required.

## Next improvements
- Multi-track piano roll
- Playback (Web Audio or soundfont)
- Save / load MIDI
- Chat-style agent interaction pane
