//! schema.zig — canonical struct definitions for all knowledge entities
//! Phase 7 — src/common/
//! These are the ground-truth data models used by ontology, library, naming, and search.
//! Defined from v0.1.0 scope spec.

const std = @import("std");
const EntityId = @import("id.zig").EntityId;

// ---------------------------------------------------------------------------
// Governance status (applies to concepts, relations, names)
// ---------------------------------------------------------------------------

pub const Status = enum {
    proposed,
    validated,
    variant,
    deprecated,
    forked,
};

// ---------------------------------------------------------------------------
// Concept (ontology term)
// ---------------------------------------------------------------------------

pub const Concept = struct {
    id:           EntityId,
    urn:          []const u8,        // arcis:concept:<id>
    label:        []const u8,        // canonical display name
    definition:   []const u8,        // plain-text definition
    domain:       []const u8,        // e.g. "linguistics", "cosmology"
    status:       Status,
    modifiable:   bool,              // false = locked (canonical source)
    source_urns:  [][]const u8,      // source text URNs that define this concept
    created_at:   i64,               // Unix ms
    updated_at:   i64,
};

// ---------------------------------------------------------------------------
// Relation (concept → concept edge)
// ---------------------------------------------------------------------------

pub const RelationKind = enum {
    broader,       // skos:broader
    narrower,      // skos:narrower
    related,       // skos:related
    equivalent,    // owl:equivalentClass
    contrasts,     // domain-specific opposition
    derives_from,  // etymological / historical derivation
};

pub const Relation = struct {
    id:         EntityId,
    urn:        []const u8,
    src_id:     EntityId,
    dst_id:     EntityId,
    kind:       RelationKind,
    status:     Status,
    note:       []const u8,
    created_at: i64,
};

// ---------------------------------------------------------------------------
// Text (ancient / library document)
// ---------------------------------------------------------------------------

pub const TextRecord = struct {
    id:               EntityId,
    urn:              []const u8,      // arcis:text:<id>
    canonical_urn:    []const u8,      // external canonical URN (e.g. CTS)
    title:            []const u8,
    author:           []const u8,
    language:         []const u8,      // ISO 639-3 code, e.g. "grc", "lat", "heb"
    period:           []const u8,      // e.g. "Classical", "Hellenistic"
    source_tradition: []const u8,      // e.g. "Greek", "Latin", "Mesopotamian"
    has_translation:  bool,
    translation_lang: []const u8,      // ISO 639-3 if has_translation
    thematic_tags:    [][]const u8,    // e.g. ["philosophy","ethics"]
    body:             []const u8,      // full UTF-8 text body (may be empty pre-import)
    created_at:       i64,
    updated_at:       i64,
};

// ---------------------------------------------------------------------------
// Annotation (free-form note on any entity)
// ---------------------------------------------------------------------------

pub const Annotation = struct {
    id:         EntityId,
    target_urn: []const u8,   // URN of annotated entity
    author:     []const u8,
    body:       []const u8,
    created_at: i64,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Status enum has five values" {
    try std.testing.expectEqual(@as(usize, 5), std.meta.fields(Status).len);
}

test "RelationKind enum has six values" {
    try std.testing.expectEqual(@as(usize, 6), std.meta.fields(RelationKind).len);
}
