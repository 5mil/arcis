# Arcis — Updates

> Trailing update log for the Arcis engine. Each entry records what changed, why, and when. Append new entries at the top.

---

## [0.4.0] — 2026-06-24

### Status: Scaffolded — Phases 1–11 Complete

### Added

**Phase 5 — `src/media/`** (7 files + session)
`audio.zig` · `mel.zig` · `whisper.zig` · `bark_tokenizer.zig` · `bark.zig` · `encodec.zig` · `diffusion.zig` · `media_session.zig`
PCM I/O and WAV reader. STFT → mel filterbank → log-mel (80-bin, 16 kHz). Whisper encoder + decoder with GGUF weight loading and beam search. Bark: text → semantic → coarse → fine acoustic token prediction. EnCodec neural audio codec, token → waveform decode. DDPM/DDIM scheduler, UNet denoising loop, latent decode for image generation. Unified MediaSession: ASR / TTS / image-gen dispatch.

**Phase 6 — `src/workflow/`** (7 files)
`graph.zig` · `node.zig` · `trigger.zig` · `job.zig` · `scheduler.zig` · `runner.zig` · `workflow_session.zig`
DAG graph with Kahn's topological sort and cycle detection. Payload tagged union (text/bytes/number/flag/null), NodeRegistry, typed NodeRunFn. Trigger types: manual / schedule / event / webhook; CronSpec; cronFires(). Job lifecycle: pending → running → completed / failed; JobStore. Tick-based scheduler with fireEvent and fireWebhook dispatch queue. Topo-order runner with payload propagation and per-node result recording. WorkflowSession: registerWorkflow, addTrigger, runNow, tick, fireEvent, getJob.

**Phase 7 — `src/common/` · `src/import/` · `src/export/`** (7 files)
`id.zig` · `schema.zig` · `store.zig` · `importer.zig` · `batch.zig` · `exporter.zig` · `serializer.zig`
EntityId/URN system: makeUrn() produces arcis:concept:00000042, IdSequence per-kind monotonic counters. Canonical schemas: Concept, Relation, TextRecord, Annotation. Status enum: proposed / validated / variant / deprecated / forked. RelationKind: broader / narrower / related / equivalent / contrasts / derives_from. Generic EntityStore(T): O(1) ID lookup via AutoHashMap, swap-remove. Import: format detection (txt/json/xml/auto), TEI XML tag-strip, JSON body extraction, BatchImporter directory scan. Export: textToJson, textToPlain, textToTei, conceptToJson, writeToFile, NDJSON bulk dump.

**Phase 8 — `src/ontology/` · `src/library/`** (4 files)
`concept_store.zig` · `terminology.zig` · `catalog.zig` · `viewer.zig`
ConceptStore: CRUD, directed relation graph (relationsFrom/To), governance setStatus. TerminologyDirectory: propose → validate → deprecate → fork; listByDomain, listByStatus. Catalog: ingest/ingestFile, TagIndex (inverted tag → IDs), findByTag/Language/Tradition. Viewer: byte-level pagination by page_size, findInText keyword offset scan.

**Phase 9 — `src/naming/`** (2 files)
`rules.zig` · `name_store.zig`
10 cultural phoneme tables: Greek, Latin, Sumerian, Arabic, Norse, Sanskrit + fallbacks (Akkadian, Hebrew, Celtic, Egyptian). Rank hierarchy: initiate / adept / scholar / sage / archon / sovereign with authentic suffixes (-vel / -keth / -oran / -arxis / -solun). generateName(tradition, rank, seed) builds onset + nucleus + coda + suffix with capital first letter. NameStore: generateAndStore with 16-attempt collision retry, NameRecord (kind/tradition/rank/variant_of), uniqueness index.

**Phase 10 — `src/search/`** (2 files)
`index.zig` · `query.zig`
KeywordIndex: inverted word map, indexDocument (tokenize → deduplicate per doc), search. UnifiedSearchIndex: keyword + vector layers bridged to Phase 3 VectorIndex. QueryEngine: keyword / semantic / hybrid / name dispatch. Hybrid = keyword-first + semantic merged result slice.

**Phase 11 — `src/api/` · `src/dashboard/`** (4 files)
`server.zig` · `tier.zig` · `views.zig` · `arcis_session.zig`
HTTP Router: Route table, Request/Response types, HandlerFn, TCP listener stub on port 8080. TierDispatcher: Forma/Figura/Visio capability bitmask; addRoute(min_tier, route) propagates routes upward. View payload structs: ReadingView, TermView, SearchView, AdminView, NamingView; ViewBuilder assembles from subsystem data. ArcisSession: root object — IdSequence, ConceptStore, TermDir, Catalog, NameStore, UnifiedSearch, WorkflowSession, TierDispatcher, ViewBuilder all wired. init(allocator, tier_name) accepts "forma" / "figura" / "visio".

### Phase Status

| Phase | Name | Modules | Status |
|---|---|---|---|
| 1 | Core Primitives | `src/core/` | ✅ Scaffolded |
| 2 | Inference Engine | `src/infer/` | ✅ Scaffolded |
| 3 | RAG Pipeline | `src/rag/` | ✅ Scaffolded |
| 4 | Agent Orchestration | `src/agents/` | ✅ Scaffolded |
| 5 | Media Pipelines | `src/media/` | ✅ Scaffolded |
| 6 | Workflow Engine | `src/workflow/` | ✅ Scaffolded |
| 7 | Knowledge Foundation | `src/common/`, `src/import/`, `src/export/` | ✅ Scaffolded |
| 8 | Ontology & Library | `src/ontology/`, `src/library/` | ✅ Scaffolded |
| 9 | Naming Engine | `src/naming/` | ✅ Scaffolded |
| 10 | Search & Semantics | `src/search/` | ✅ Scaffolded |
| 11 | Dashboard & API | `src/dashboard/`, `src/api/` | ✅ Scaffolded |
| 12 | Refinement & Delivery | `tests/`, `docs/`, `examples/`, `build.zig` | 🔜 Next |

### Stats
- 30 source files across 11 phases
- ~3,200 lines of Zig scaffolding
- Single root object: ArcisSession
- One binary, zero external runtimes

### Next Review
- 2026-07-01

---

## [0.3.0] — 2026-06-24

### Status: Planning — Phase 5

### Phase 5 — `src/media/` Spec

#### Build Order (bottom-up)

```
audio.zig           ← raw PCM I/O, WAV reader, sample rate conversion
mel.zig             ← STFT → power spectrum → mel filterbank → log-mel
whisper.zig         ← Whisper encoder+decoder, GGUF weight loading, beam search
bark_tokenizer.zig  ← Bark text → semantic token encoding (EnCodec vocab)
bark.zig            ← semantic → coarse → fine acoustic token prediction
encodec.zig         ← EnCodec neural audio codec, token → waveform decode
diffusion.zig       ← DDPM/DDIM scheduler, UNet denoising loop, latent decode
media_session.zig   ← unified entry point: ASR, TTS, image-gen dispatch
```

#### Key Data Flows

```
ASR: WAV file → audio.zig → mel.zig → whisper.zig → []const u8 transcript
TTS: []const u8 text → bark_tokenizer.zig → bark.zig → encodec.zig → PCM f32
IMG: []const u8 prompt → whisper encoder (CLIP-style) → diffusion.zig → []u8 pixels
```

#### Dependencies on Existing Subsystems
- `src/core/tensor.zig` — all intermediate buffers use the existing Tensor type
- `src/infer/gguf.zig` + `loader.zig` — Whisper and Bark weights load via GGUF mmap
- `src/infer/attention.zig` + `transformer.zig` — reused by Whisper encoder/decoder and Bark stages
- `src/infer/sampler.zig` — Bark autoregressive token sampling reuses temperature/top-k/top-p
- `src/infer/bpe.zig` + `vocab.zig` — bark_tokenizer.zig extends BPE, does not replace it

#### Completion Criteria
- [ ] `audio.zig` — WAV round-trip test (read → normalize → write)
- [ ] `mel.zig` — mel output matches reference (80-bin, 16 kHz, 25 ms window)
- [ ] `whisper.zig` — transcribes `tiny.en` GGUF on a 10-second sample
- [ ] `bark_tokenizer.zig` — encodes a short sentence to semantic tokens
- [ ] `bark.zig` — generates coarse acoustic tokens end-to-end
- [ ] `encodec.zig` — decodes tokens to a playable WAV
- [ ] `diffusion.zig` — produces a 512×512 pixel buffer from a prompt
- [ ] `media_session.zig` — all three dispatch paths exercised in a single test

### Unified Phase Plan (as of 2026-06-24)

| Phase | Name | Modules | Status |
|---|---|---|---|
| 1 | Core Primitives | `src/core/` | Complete |
| 2 | Inference Engine | `src/infer/` | Complete |
| 3 | RAG Pipeline | `src/rag/` | Complete |
| 4 | Agent Orchestration | `src/agents/` | Complete |
| 5 | Media Pipelines | `src/media/` | Next |
| 6 | Workflow Engine | `src/workflow/` | Queued |
| 7 | Knowledge Foundation | `src/common/`, `src/import/`, `src/export/` | Queued |
| 8 | Ontology & Library | `src/ontology/`, `src/library/` | Queued |
| 9 | Naming Engine | `src/naming/` | Queued |
| 10 | Search & Semantics | `src/search/` | Queued |
| 11 | Dashboard & API | `src/dashboard/`, `src/api/` | Queued |
| 12 | Refinement & Delivery | `tests/`, `docs/`, `examples/` | Queued |

### Next Review
- 2026-07-01

---

## [0.2.0] — 2026-06-24

### Status: Complete — Phases 1–4

### Added
- Completed `src/core/`: tensor, dtype, shape, config
- Completed `src/infer/`: gguf, loader, model, vocab, bpe, tokenizer, rope, kvcache, attention, transformer, sampler, session
- Completed `src/rag/`: chunker, embedder, index, retriever, pipeline
- Completed `src/agents/`: tool, planner, orchestrator

### Next Review
- 2026-07-01

---

## [0.1.0] — 2026-06-24

### Status: Planning

### Added
- Established engine identity: **Arcis** — Zig-native AI engine and knowledge citadel.
- Defined total scope: inference, RAG, multi-agent orchestration, media pipelines, workflow automation, ancient text library, ontology/terminology directory, space and wizard naming system, and unified dashboard.
- Designed modular repository structure:
  - `src/core/`
  - `src/ontology/`
  - `src/library/`
  - `src/naming/`
  - `src/search/`
  - `src/dashboard/`
  - `src/api/`
  - `src/import/`
  - `src/export/`
  - `src/common/`
  - `tests/`
  - `docs/`
  - `examples/`
- Defined terminology directory schema with concept IDs, definitions, relations, status flags, source-text citations, and modifiability rules.
- Defined ancient text library module with metadata fields: title, author, language, period, source tradition, translation availability, canonical URN, and thematic tags.
- Defined naming system: two-layer space/wizard naming with authentic phonetics, cultural roots, status hierarchy, and variant tracking.
- Defined incremental build phases:
  1. Foundation — data model, IDs, schemas
  2. Library and terminology — ingestion, catalog, viewer, cross-links
  3. Dashboard core — reading view, term view, entity view, admin
  4. Naming and semantics — name generation, semantic search, suggestions
  5. Refinement — versioning, provenance, export, bulk edit
- Defined trailing update format appended to all scope documents and phase specs.
- Defined governance model: proposed, validated, variant, deprecated, forked.
- Defined release cadence: weekly ingest/fix, monthly subsystem improvement, quarterly capability delivery.

### Changed
- N/A (initial entry)

### Notes
- Scope remains open and expandable. Terminology, text sources, and naming rules will grow incrementally.
- All subsystems to be written in Zig; dashboard UI follows the three-tier model from `zigllm-ui` (forma / figura / visio).
- Sister repos: [zigllm-ui](https://github.com/5mil/zigllm-ui), [zigllm-os](https://github.com/5mil/zigllm-os)

### Next Review
- 2026-07-01
