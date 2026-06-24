# Arcis — Updates

> Trailing update log for the Arcis engine. Each entry records what changed, why, and when. Append new entries at the top.

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
