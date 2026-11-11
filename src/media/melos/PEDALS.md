# Melos Instruments & Crowd Pedals

## Instruments
`instruments.zig` defines a GM-style library (Piano, Synth Lead, Bass, Drums, etc.).
Tracks can be assigned an instrument; the live generator and MIDI exporter respect the program number and role.

## Crowd-built effects pedals
Audience members design pedals in the GUI (Pedals tab):
- Name, target instrument, description
- Parameters: pitch shift, velocity scale, reverb, delay

Submitted pedals appear in a list. The performer can:
- Approve
- Activate (applies to subsequent live notes for that instrument)

## Backend
- `pedals.zig` — Pedal, PedalBoard, submit / approve / activate / applyActive
- Active pedals modulate MidiNotes before they are rendered or exported

## API (add to router)
- `POST /api/melos/pedals/submit`
- `POST /api/melos/pedals/approve`
- `POST /api/melos/pedals/activate`
- `GET  /api/melos/pedals`

## Integration
Call `PedalBoard.applyActive(instrument, notes)` inside the live step or MIDI export path so approved pedals affect the sound in real time.

The GUI Pedals tab is ready and talks to these endpoints.
