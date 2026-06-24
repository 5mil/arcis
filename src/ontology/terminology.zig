//! terminology.zig — governed terminology directory: propose, validate, deprecate terms
//! Phase 8 — src/ontology/
//! Implements the governance model from v0.1.0: proposed → validated → deprecated/forked

const std = @import("std");
const Allocator   = std.mem.Allocator;
const ConceptStore = @import("concept_store.zig").ConceptStore;
const Status      = @import("../common/schema.zig").Status;
const EntityId    = @import("../common/id.zig").EntityId;

// ---------------------------------------------------------------------------
// TerminologyDirectory
// ---------------------------------------------------------------------------

pub const TerminologyDirectory = struct {
    store:     *ConceptStore,
    allocator: Allocator,

    pub fn init(allocator: Allocator, store: *ConceptStore) TerminologyDirectory {
        return .{ .store = store, .allocator = allocator };
    }

    /// Propose a new term. Status starts as .proposed.
    pub fn propose(
        self: *TerminologyDirectory,
        label: []const u8,
        definition: []const u8,
        domain: []const u8,
    ) !EntityId {
        return try self.store.addConcept(label, definition, domain, .proposed, true);
    }

    /// Validate a proposed term (governance approval).
    pub fn validate(self: *TerminologyDirectory, id: EntityId) bool {
        return self.store.setStatus(id, .validated);
    }

    /// Deprecate a term (still accessible, no longer canonical).
    pub fn deprecate(self: *TerminologyDirectory, id: EntityId) bool {
        return self.store.setStatus(id, .deprecated);
    }

    /// Fork a term: create a variant copy with .forked status.
    pub fn fork(
        self: *TerminologyDirectory,
        source_id: EntityId,
        new_label: []const u8,
        new_definition: []const u8,
    ) !EntityId {
        const src = self.store.concepts.getById(source_id) orelse return error.ConceptNotFound;
        const new_id = try self.store.addConcept(
            new_label, new_definition, src.domain, .forked, true,
        );
        // Record derives_from relation.
        _ = try self.store.addRelation(new_id, source_id, .derives_from, "forked");
        return new_id;
    }

    /// List all terms in a given domain.
    pub fn listByDomain(
        self: *TerminologyDirectory,
        domain: []const u8,
        out: *std.ArrayList(EntityId),
    ) !void {
        for (self.store.concepts.items.items) |c| {
            if (std.mem.eql(u8, c.domain, domain)) try out.append(c.id);
        }
    }

    /// List all terms with a given status.
    pub fn listByStatus(
        self: *TerminologyDirectory,
        status: Status,
        out: *std.ArrayList(EntityId),
    ) !void {
        for (self.store.concepts.items.items) |c| {
            if (c.status == status) try out.append(c.id);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TerminologyDirectory propose and validate" {
    const allocator = std.testing.allocator;
    var seq = @import("../common/id.zig").IdSequence.init();
    var cs  = ConceptStore.init(allocator, &seq);
    defer cs.deinit();
    var td  = TerminologyDirectory.init(allocator, &cs);

    const id = try td.propose("arete", "excellence / virtue", "ethics");
    const c  = cs.concepts.getById(id);
    try std.testing.expectEqual(Status.proposed, c.?.status);

    try std.testing.expect(td.validate(id));
    try std.testing.expectEqual(Status.validated, cs.concepts.getById(id).?.status);
}

test "TerminologyDirectory fork" {
    const allocator = std.testing.allocator;
    var seq = @import("../common/id.zig").IdSequence.init();
    var cs  = ConceptStore.init(allocator, &seq);
    defer cs.deinit();
    var td  = TerminologyDirectory.init(allocator, &cs);

    const src = try td.propose("eidos", "form", "metaphysics");
    const fork_id = try td.fork(src, "idea", "Platonic form");
    try std.testing.expect(fork_id != src);
    try std.testing.expectEqual(
        Status.forked, cs.concepts.getById(fork_id).?.status,
    );
}
