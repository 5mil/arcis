//! concept_store.zig — ontology concept catalog: CRUD, governance, relation graph
//! Phase 8 — src/ontology/
//! Depends on: src/common/schema.zig, store.zig, id.zig

const std = @import("std");
const Allocator  = std.mem.Allocator;
const Concept    = @import("../common/schema.zig").Concept;
const Relation   = @import("../common/schema.zig").Relation;
const RelationKind = @import("../common/schema.zig").RelationKind;
const Status     = @import("../common/schema.zig").Status;
const EntityStore = @import("../common/store.zig").EntityStore;
const EntityId   = @import("../common/id.zig").EntityId;
const IdSequence = @import("../common/id.zig").IdSequence;
const makeUrn    = @import("../common/id.zig").makeUrn;
const URN_BUF_SIZE = @import("../common/id.zig").URN_BUF_SIZE;

// ---------------------------------------------------------------------------
// ConceptStore
// ---------------------------------------------------------------------------

pub const ConceptStore = struct {
    concepts:   EntityStore(Concept),
    relations:  EntityStore(Relation),
    seq:        *IdSequence,
    allocator:  Allocator,

    pub fn init(allocator: Allocator, seq: *IdSequence) ConceptStore {
        return .{
            .concepts  = EntityStore(Concept).init(allocator),
            .relations = EntityStore(Relation).init(allocator),
            .seq       = seq,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConceptStore) void {
        self.concepts.deinit();
        self.relations.deinit();
    }

    /// Add a new concept. Returns assigned EntityId.
    pub fn addConcept(
        self: *ConceptStore,
        label: []const u8,
        definition: []const u8,
        domain: []const u8,
        status: Status,
        modifiable: bool,
    ) !EntityId {
        const id  = self.seq.next(.concept);
        var urn_buf: [URN_BUF_SIZE]u8 = undefined;
        const urn = try self.allocator.dupe(u8, makeUrn(.concept, id, &urn_buf));
        const now = std.time.milliTimestamp();
        try self.concepts.put(.{
            .id          = id,
            .urn         = urn,
            .label       = label,
            .definition  = definition,
            .domain      = domain,
            .status      = status,
            .modifiable  = modifiable,
            .source_urns = &.{},
            .created_at  = now,
            .updated_at  = now,
        });
        return id;
    }

    /// Add a directed relation between two concepts.
    pub fn addRelation(
        self: *ConceptStore,
        src: EntityId,
        dst: EntityId,
        kind: RelationKind,
        note: []const u8,
    ) !EntityId {
        const id = self.seq.next(.relation);
        var urn_buf: [URN_BUF_SIZE]u8 = undefined;
        const urn = try self.allocator.dupe(u8, makeUrn(.relation, id, &urn_buf));
        try self.relations.put(.{
            .id         = id,
            .urn        = urn,
            .src_id     = src,
            .dst_id     = dst,
            .kind       = kind,
            .status     = .validated,
            .note       = note,
            .created_at = std.time.milliTimestamp(),
        });
        return id;
    }

    /// Return all relations where src_id == id.
    pub fn relationsFrom(self: *ConceptStore, id: EntityId, out: *std.ArrayList(Relation)) !void {
        for (self.relations.items.items) |r| {
            if (r.src_id == id) try out.append(r);
        }
    }

    /// Return all relations where dst_id == id.
    pub fn relationsTo(self: *ConceptStore, id: EntityId, out: *std.ArrayList(Relation)) !void {
        for (self.relations.items.items) |r| {
            if (r.dst_id == id) try out.append(r);
        }
    }

    /// Update concept status (governance transition).
    pub fn setStatus(self: *ConceptStore, id: EntityId, status: Status) bool {
        const c = self.concepts.getById(id) orelse return false;
        if (!c.modifiable) return false;
        c.status = status;
        c.updated_at = std.time.milliTimestamp();
        return true;
    }

    pub fn count(self: ConceptStore) usize {
        return self.concepts.count();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ConceptStore add and retrieve" {
    const allocator = std.testing.allocator;
    var seq = IdSequence.init();
    var cs  = ConceptStore.init(allocator, &seq);
    defer cs.deinit();

    const id = try cs.addConcept("logos", "reason / word", "philosophy", .validated, true);
    try std.testing.expectEqual(@as(EntityId, 1), id);
    try std.testing.expectEqual(@as(usize, 1), cs.count());

    const found = cs.concepts.getById(id);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("logos", found.?.label);
}

test "ConceptStore relation" {
    const allocator = std.testing.allocator;
    var seq = IdSequence.init();
    var cs  = ConceptStore.init(allocator, &seq);
    defer cs.deinit();

    const a = try cs.addConcept("being", "existence", "metaphysics", .validated, true);
    const b = try cs.addConcept("becoming", "change", "metaphysics", .validated, true);
    _ = try cs.addRelation(a, b, .contrasts, "");

    var out = std.ArrayList(Relation).init(allocator);
    defer out.deinit();
    try cs.relationsFrom(a, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(RelationKind.contrasts, out.items[0].kind);
}
