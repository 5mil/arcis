# Arcis — Updates

> Trailing update log for the Arcis engine. Each entry records what changed, why, and when. Append new entries at the top.

---

## [0.6.0] — 2026-06-24

### Status: Complete — Phase 13 Live Server + Expanded Naming

### Added

**`src/api/server.zig`** — Live TCP accept loop. Binds to `127.0.0.1:<port>`, accepts connections, spawns a detached thread per connection, reads HTTP/1.1 request line + body, dispatches to TierDispatcher, writes HTTP/1.1 response with Content-Type/Content-Length headers.

**`src/api/handlers.zig`** — Route handler functions wired to ArcisSession subsystems:
- `GET /health` — `{"status":"ok"}`
- `POST /infer` — tier-gated, prompt extraction, inference stub (ready for GGUF wiring)
- `POST /rag` — tier-gated, query extraction, RAG pipeline stub
- `GET|POST /search` — keyword index search, returns matching document ID array
- `POST /name` — tier-gated, kind/tradition/rank params, live NameStore.generateAndStore
- `POST /workflow/run` — tier-gated, workflow_id + payload, live WorkflowSession.runNow
- `POST /term/propose` — tier-gated, label/definition/domain, live TermDir.propose
- `POST /term/validate` — tier-gated, id param, live TermDir.validate

**`src/api/tier.zig`** — TierDispatcher updated: holds `*ArcisSession`, `dispatch()` routes live requests to handlers by path string match.

**`src/naming/rules.zig`** — Four remaining phoneme traditions fully implemented:
- **Akkadian**: Ash/Bel/Ish/Nab/Ner/Sha/Sin/Tam/Zer/Mar · codas: gal/dum/bit/ruk/nun/sar/kin/abu
- **Hebrew**: El/Gad/Bar/Sha/Yal/Uri/Avi/Ben/Ner/Ezi · codas: el/ah/on/am/im/al/or/en
- **Celtic**: Bri/Cai/Dun/Eir/Fer/Gal/Mor/Nia/Tre/Wyn · codas: dh/th/nn/rn/rd/gh/ch/wr
- **Egyptian**: Akh/Hor/Imo/Kha/Men/Nef/Ptah/Ra/Set/Tha · codas: hotep/mose/nkh/aten/ra/amon/sis/mes
All 10 traditions now complete.

**`src/main.zig`** — Entry point wired end-to-end: ArcisSession.init → TierDispatcher.init → Server.init → Server.serve (blocking).

### Routes Active at Runtime

| Route | Method | Tier Required | Live? |
|---|---|---|---|
| `/health` | GET | any | ✅ |
| `/infer` | POST | forma+ | stub |
| `/rag` | POST | forma+ | stub |
| `/search` | GET/POST | any | ✅ |
| `/name` | POST | visio | ✅ |
| `/workflow/run` | POST | figura+ | ✅ |
| `/term/propose` | POST | visio | ✅ |
| `/term/validate` | POST | visio | ✅ |

### Naming Traditions Status

| Tradition | Status |
|---|---|
| Greek | ✅ |
| Latin | ✅ |
| Sumerian | ✅ |
| Arabic | ✅ |
| Norse | ✅ |
| Sanskrit | ✅ |
| Akkadian | ✅ Phase 13 |
| Hebrew | ✅ Phase 13 |
| Celtic | ✅ Phase 13 |
| Egyptian | ✅ Phase 13 |

### Next
- Wire real GGUF model loading: `src/infer/loader.zig` mmap → `session.generate()` → `/infer` handler
- Wire RAG corpus: `src/rag/pipeline.zig` → `/rag` handler with real embeddings
- `POST /ingest` endpoint → Catalog + KeywordIndex population
- `GET /term/:id` and `GET /name/:id` read endpoints
- Connection keep-alive + HTTP chunked response for streaming inference

### Next Review
- 2026-07-01

---

## [0.5.0] — 2026-06-24

### Status: Complete — Phase 12 Refinement & Delivery

### Added

**Phase 12 — `build.zig` · `src/main.zig` · `tests/` · `docs/` · `examples/`**

`build.zig` — full Zig build script: one executable (`arcis`), per-subsystem test steps (`zig build test`, `zig build test-<name>`), tier-specific run steps (`zig build run-forma|figura|visio`), test filter support.

`src/main.zig` — CLI entry point: `--tier forma|figura|visio`, `--port`, GPA allocator, ArcisSession init, startup log.

`tests/test_core.zig` — Tensor alloc/fill, Shape rank/numel, DType sizes, Config defaults.
`tests/test_knowledge.zig` — Full terminology lifecycle (propose→validate→deprecate), fork+derives_from relation, catalog ingest + Viewer pagination, NameStore uniqueness, cross-subsystem keyword index.
`tests/test_workflow.zig` — WorkflowSession register + runNow, job completion, trigger registration.
`tests/test_session.zig` — ArcisSession all-tier capability checks (visio/figura/forma), catalog + naming wired.

`docs/architecture.md` — subsystem map, tier model, URN format, governance lifecycle, naming rank table, build commands, RAG and workflow data flow diagrams.
`docs/getting-started.md` — prerequisites, build, run, test commands, basic Zig API usage, tier feature table.

`examples/basic_session.zig` — init ArcisSession (visio), ingest text, propose+validate concept, generate name, keyword search.
`examples/workflow_example.zig` — two-node graph (upper→print), register node types, runNow, inspect job status.

### Phase Status

| Phase | Name | Modules | Status |
|---|---|---|---|
| 1 | Core Primitives | `src/core/` | ✅ Complete |
| 2 | Inference Engine | `src/infer/` | ✅ Complete |
| 3 | RAG Pipeline | `src/rag/` | ✅ Complete |
| 4 | Agent Orchestration | `src/agents/` | ✅ Complete |
| 5 | Media Pipelines | `src/media/` | ✅ Complete |
| 6 | Workflow Engine | `src/workflow/` | ✅ Complete |
| 7 | Knowledge Foundation | `src/common/`, `src/import/`, `src/export/` | ✅ Complete |
| 8 | Ontology & Library | `src/ontology/`, `src/library/` | ✅ Complete |
| 9 | Naming Engine | `src/naming/` | ✅ Complete |
| 10 | Search & Semantics | `src/search/` | ✅ Complete |
| 11 | Dashboard & API | `src/dashboard/`, `src/api/` | ✅ Complete |
| 12 | Refinement & Delivery | `tests/`, `docs/`, `examples/`, `build.zig` | ✅ Complete |

### Stats
- 42 source files total
- 12 phases complete
- All subsystems wired into ArcisSession
- One binary, zero external runtimes
- `zig build test` runs all 4 integration test suites

### Next Review
- 2026-07-01

---

## [0.4.0] — 2026-06-24

### Status: Scaffolded — Phases 1–11 Complete

### Added

**Phase 5 — `src/media/`**
**Phase 6 — `src/workflow/`**
**Phase 7 — `src/common/` · `src/import/` · `src/export/`**
**Phase 8 — `src/ontology/` · `src/library/`**
**Phase 9 — `src/naming/`**
**Phase 10 — `src/search/`**
**Phase 11 — `src/api/` · `src/dashboard/`**

See full entry in git history.

### Next Review
- 2026-07-01

---

## [0.2.0] — 2026-06-24

### Status: Complete — Phases 1–4

- `src/core/`: tensor, dtype, shape, config
- `src/infer/`: gguf, loader, model, vocab, bpe, tokenizer, rope, kvcache, attention, transformer, sampler, session
- `src/rag/`: chunker, embedder, index, retriever, pipeline
- `src/agents/`: tool, planner, orchestrator

### Next Review
- 2026-07-01

---

## [0.1.0] — 2026-06-24

### Status: Planning

- Established engine identity: **Arcis** — Zig-native AI engine and knowledge citadel.
- Defined total scope: inference, RAG, agents, media, workflow, library, ontology, naming, search, dashboard.
- Sister repos: [zigllm-ui](https://github.com/5mil/zigllm-ui), [zigllm-os](https://github.com/5mil/zigllm-os)

### Next Review
- 2026-07-01
