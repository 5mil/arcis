# Melos Official Voicebank Bridge

Melos does **not** embed or redistribute commercial voicebanks.

It provides a premium controller + export path so users who have purchased official voices can use them with Melos workflows.

## Supported path (current)

1. Build a `VocalTrack` (notes, lyrics, phonemes, expression parameters, structure section).
2. Export MIDI + timed lyrics + expression JSON via `vocal.exportForOfficial`.
3. User loads the MIDI + lyrics into:
   - VOCALOID Editor (standalone or VST/AU)
   - Synthesizer V Studio
   - ACE Studio
   - Emvoice One
   - Any other MIDI+lyrics vocal engine
4. Render with the purchased voicebank.
5. Optionally re-import the audio/stems into Melos for mixing or live use.

## VST/AU host path (planned)

When the user has the official plugin installed and licensed on the same machine:

- Melos can host or communicate with the VST/AU.
- Send MIDI notes, lyrics/phonemes, and expression parameters in real time.
- Receive rendered audio for the live mix or Kick stream.
- Crowd pedals and structure tags continue to modulate what is sent to the official engine.

## Files

- `vocal.zig` — `VocalTrack`, `Phoneme`, `VocalExpression`, export helpers, host placeholder.
- Structure tags (`[Verse]`, `[Chorus]`, etc.) already drive section-aware changes before export.

This keeps full legal compliance while giving a higher-quality, live-capable workflow than the standalone official editors alone.
