# Arcis — Architecture

> One binary. Zero external runtimes. Three capability tiers.

## Overview

Arcis is a unified full-stack AI engine written entirely in Zig. All subsystems — from tensor primitives to workflow automation to the ancient text library — are implemented natively with no FFI, no C dependencies, and no external runtimes.

## Tier Model

| Tier | Capabilities |
|---|---|
| **Forma** | Inference + RAG only |
| **Figura** | + Agents + Workflow |
| **Visio** | + Media + Ontology + Library + Naming + Dashboard |

Tiers are selected at runtime via `--tier forma|figura|visio`. They are not separate builds.

## Subsystem Map

```
ArcisSession (root)
├── src/core/          ← tensor, dtype, shape, config
├── src/infer/         ← GGUF, BPE, RoPE, KV cache, attention, transformer, sampler, session
├── src/rag/           ← chunker, embedder, vector index, retriever, pipeline
├── src/agents/        ← tool registry, ReAct planner, orchestrator
├── src/media/         ← ASR (Whisper), TTS (Bark+EnCodec), image-gen (DDPM/DDIM)
├── src/workflow/      ← DAG runner, triggers, job lifecycle, scheduler
├── src/common/        ← EntityId/URN, canonical schemas, EntityStore(T)
├── src/import/        ← txt/json/TEI XML ingestion, batch directory scan
├── src/export/        ← JSON, plain text, TEI XML, NDJSON bulk dump
├── src/ontology/      ← ConceptStore, TerminologyDirectory (propose→fork)
├── src/library/       ← Catalog (TagIndex), Viewer (pagination, search)
├── src/naming/        ← 10 cultural phoneme tables, Rank hierarchy, NameStore
├── src/search/        ← KeywordIndex, UnifiedSearchIndex, QueryEngine
├── src/api/           ← HTTP Router, TierDispatcher, HandlerFn
└── src/dashboard/     ← view payloads, ViewBuilder, ArcisSession root
```

## Canonical URN Format

```
arcis:<kind>:<id>
arcis:concept:00000042
arcis:text:00000001
arcis:name:00000007
```

## Governance Model

Terminology terms follow a strict lifecycle:
```
proposed → validated → deprecated
                    └→ forked → (new branch, derives_from relation)
```

## Naming System

Names are generated from cultural phoneme tables (onset + nucleus + coda) with rank suffixes appended:

| Rank | Suffix |
|---|---|
| initiate | (none) |
| adept | -vel |
| scholar | -keth |
| sage | -oran |
| archon | -arxis |
| sovereign | -solun |

## Build

```sh
zig build              # build binary
zig build run          # run in default (visio) tier
zig build run-forma    # run in forma tier
zig build test         # run all subsystem tests
zig build test-core    # run only core tests
```

## Data Flow: RAG Query

```
user query
  → Embedder.embed(query)
  → VectorIndex.topK(embedding, k)
  → assemble grounded prompt
  → Session.generate(prompt)
  → []const u8 answer
```

## Data Flow: Workflow Execution

```
WorkflowSession.runNow(wf_id, payload)
  → Graph.topoSort()
  → for each node: NodeRegistry.find(name) → NodeRunFn(io)
  → propagate output payload to downstream nodes
  → Job.status = .completed
```
