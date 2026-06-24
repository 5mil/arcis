//! id.zig — canonical ID types and generation for all knowledge entities
//! Phase 7 — src/common/
//! Used by: src/ontology/, src/library/, src/naming/, src/search/

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// ID types
// ---------------------------------------------------------------------------

/// Opaque numeric ID shared by all entity kinds.
pub const EntityId = u64;

/// Entity kind tag — embedded in URN and log entries.
pub const EntityKind = enum {
    concept,     // ontology term
    relation,    // concept-to-concept relation
    text,        // ancient/library text
    name,        // generated space or wizard name
    annotation,  // free-form note on any entity
};

/// Canonical URN: arcis:<kind>:<id>  e.g. "arcis:concept:00000042"
pub const URN_PREFIX = "arcis";
pub const URN_BUF_SIZE = 32;

pub fn makeUrn(kind: EntityKind, id: EntityId, buf: []u8) []const u8 {
    const kind_str = switch (kind) {
        .concept    => "concept",
        .relation   => "relation",
        .text       => "text",
        .name       => "name",
        .annotation => "annotation",
    };
    const written = std.fmt.bufPrint(buf, "{s}:{s}:{d:0>8}", .{ URN_PREFIX, kind_str, id })
        catch buf[0..0];
    return written;
}

// ---------------------------------------------------------------------------
// IdSequence — monotonic ID generator per kind
// ---------------------------------------------------------------------------

pub const IdSequence = struct {
    counters: [std.meta.fields(EntityKind).len]EntityId,

    pub fn init() IdSequence {
        return .{ .counters = [_]EntityId{1} ** std.meta.fields(EntityKind).len };
    }

    pub fn next(self: *IdSequence, kind: EntityKind) EntityId {
        const i = @intFromEnum(kind);
        const id = self.counters[i];
        self.counters[i] += 1;
        return id;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "URN format" {
    var buf: [URN_BUF_SIZE]u8 = undefined;
    const urn = makeUrn(.concept, 42, &buf);
    try std.testing.expectEqualStrings("arcis:concept:00000042", urn);
}

test "IdSequence monotonic" {
    var seq = IdSequence.init();
    try std.testing.expectEqual(@as(EntityId, 1), seq.next(.concept));
    try std.testing.expectEqual(@as(EntityId, 2), seq.next(.concept));
    try std.testing.expectEqual(@as(EntityId, 1), seq.next(.text)); // independent counter
}
