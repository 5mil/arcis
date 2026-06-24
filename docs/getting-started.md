# Getting Started with Arcis

## Prerequisites

- Zig 0.14.0 or later
- A GGUF model file (e.g. `llama-3.2-1b.gguf`) for inference

## Build

```sh
git clone https://github.com/5mil/arcis
cd arcis
zig build
```

The binary is written to `zig-out/bin/arcis`.

## Run

```sh
# Full engine (Visio tier — default)
./zig-out/bin/arcis

# Inference + RAG only (Forma tier)
./zig-out/bin/arcis --tier forma

# Custom port
./zig-out/bin/arcis --tier visio --port 9090
```

## Run Tests

```sh
zig build test              # all subsystems
zig build test-core         # core only
zig build test-dashboard    # ArcisSession integration
zig build test-knowledge    # ontology + library + naming + search
```

## Basic Usage (Zig API)

```zig
const ArcisSession = @import("src/dashboard/arcis_session.zig").ArcisSession;

var session = try ArcisSession.init(allocator, "visio");
defer session.deinit();

// Ingest a text into the library
const id = try session.catalog.ingest(
    "Know thyself.",
    .{ .title = "Aphorism", .author = "Socrates", .language = "grc",
       .thematic_tags = &.{ "philosophy", "ethics" } },
);

// Propose a terminology concept
const concept_id = try session.terms.propose(
    "sophia", "wisdom", "philosophy",
);
_ = session.terms.validate(concept_id);

// Generate a wizard name
const name_id = try session.names.generateAndStore(.wizard, .greek, .sage, 42);
const name = session.names.names.items[0].value;
// e.g. "Mneis-oran"
_ = name;
```

## Tiers at a Glance

| Feature | Forma | Figura | Visio |
|---|---|---|---|
| Inference (GGUF) | ✅ | ✅ | ✅ |
| RAG pipeline | ✅ | ✅ | ✅ |
| Agents / ReAct | ❌ | ✅ | ✅ |
| Workflow engine | ❌ | ✅ | ✅ |
| Media (ASR/TTS/IMG) | ❌ | ❌ | ✅ |
| Ontology & Library | ❌ | ❌ | ✅ |
| Naming engine | ❌ | ❌ | ✅ |
| Dashboard | ❌ | ❌ | ✅ |
