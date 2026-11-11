# Melos — Arcis Music Module Roadmap

**Melos** (Greek: song, melody, musical phrase) is the dedicated music understanding and generation subsystem for Arcis.  
It sits on top of the existing media layer (stems, TTS, ASR) and reuses Arcis agents + workflows.

Goal: full-featured local music copilot that can both *understand* and *create* symbolic and audio music, orchestrated by agents.

## Principles
- Native Zig where practical; clean interfaces first.
- Symbolic (MIDI / score) as the primary creative representation.
- Audio backbone remains Arcis-native (stems.zig, bark, whisper).
- Agent-orchestrated (MusicAgent pattern).
- Local-first, no external runtimes required for core path.

## Roadmap

### 1. Interfaces & data formats ← **current**
Define the core types and tool contract:
- MIDI events, tracks, files
- Musical attributes (key, tempo, emotion, genre, density, …)
- Track masks / role labels (melody, bass, drums, accompaniment, …)
- Lyric–melody alignment structures
- `MelosTool` interface that agents call

### 2. MusicAgent-style orchestration layer
Register Melos tools into Arcis’s existing ToolRegistry / ReAct planner / WorkflowSession.
Enable multi-step music tasks (“generate a verse in A minor, then add drums and bass”).

### 3. Symbolic understanding foundation
Lightweight MusicBERT-style encoder + CLaMP-style language–music alignment.
Retrieval index over symbolic pieces so agents can analyze, search, and condition generation.

### 4. Text-to-symbolic generation
MuseCoco / GETMusic-inspired pipeline:
text or attribute vector → multi-track MIDI.
Start with interface + reference path; later native or hybrid backends.

### 5. Structure-aware long-form modeling
Museformer / MeloForm ideas for coherent form (verse–chorus, AABA, etc.) and longer sequences.
Builds on the representation from step 1.

### 6. Audio backbone integration
- MIDI → audio rendering (soundfont or simple synthesizer)
- Stem-aware mixing and editing
- Continue using native HTDemucs-style separation, Bark TTS, Whisper ASR

### 7. End-to-end copilot workflows
Full loops exposed via agents and the Visio-tier API:
describe → plan → generate symbolic → render → separate/edit → revise.

## Next immediate deliverable
See `types.zig` — the concrete Zig types for step 1.
