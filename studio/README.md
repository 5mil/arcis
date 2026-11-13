# Melos Studio — Lamp Room

Playable music studio for Arcis. Seed song is **Lamp Room** (A minor, 92 bpm).

This is not the older static page at `www.fizz.beer/melos/` (Melos Live watch: Kick placeholder, crowd prompt, pedal form). That page does not play Lamp Room.

## Desks

- **Song** — arrangement, piano roll, drum steps, lyrics, automation
- **Rack** — Filament / Pulse / Fold, filter, drive, EQ, compressor, chorus, delay, space, macros, mod matrix
- **Mix** — faders, pan, mute, solo, meters, stereo render
- **Wave** — destructive edit: cut, copy, paste, trim, fades, reverse, normalize, echo, EQ, denoise, de-click, pitch, speed, spectrum, markers
- **Live** — crowd prompts, audience pedals, Kick channel embed, session packet for a licensed vocal editor

The in-browser voice is Melos's own preview model. Purchased VOCALOID, Synthesizer V, ACE, and Emvoice banks are not included. Use **Download session packet** (MIDI + lyrics + expression JSON) in a editor you already own.

Song state stays in the browser (`localStorage`). No accounts.

## Run

```bash
cd studio
npm install
npm run dev
```

Dev server listens on port 8080. Production:

```bash
npm run build
npm run preview
```

## Deploy note for Goji

`www.fizz.beer` is the Arcis paper desk. Please serve this app at the Melos URL (replace or sit beside `/melos/`). Do not point `/melos/` at the old watch HTML if the goal is the playable studio.
