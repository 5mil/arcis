//! test_knowledge.zig — integration tests for ontology, library, naming, search
//! Phase 12 — tests/

const std = @import("std");
const IdSequence    = @import("../src/common/id.zig").IdSequence;
const ConceptStore  = @import("../src/ontology/concept_store.zig").ConceptStore;
const TermDir       = @import("../src/ontology/terminology.zig").TerminologyDirectory;
const Catalog       = @import("../src/library/catalog.zig").Catalog;
const Viewer        = @import("../src/library/viewer.zig").Viewer;
const NameStore     = @import("../src/naming/name_store.zig").NameStore;
const KeywordIndex  = @import("../src/search/index.zig").KeywordIndex;
const Status        = @import("../src/common/schema.zig").Status;

test "full terminology lifecycle" {
    const allocator = std.testing.allocator;
    var seq = IdSequence.init();
    var cs  = ConceptStore.init(allocator, &seq);
    defer cs.deinit();
    var td  = TermDir.init(allocator, &cs);

    const id = try td.propose("pneuma", "breath / spirit", "cosmology");
    try std.testing.expectEqual(Status.proposed, cs.concepts.getById(id).?.status);
    _ = td.validate(id);
    try std.testing.expectEqual(Status.validated, cs.concepts.getById(id).?.status);
    _ = td.deprecate(id);
    try std.testing.expectEqual(Status.deprecated, cs.concepts.getById(id).?.status);
}

test "fork creates derives_from relation" {
    const allocator = std.testing.allocator;
    var seq = IdSequence.init();
    var cs  = ConceptStore.init(allocator, &seq);
    defer cs.deinit();
    var td  = TermDir.init(allocator, &cs);

    const src     = try td.propose("nous", "mind", "philosophy");
    const fork_id = try td.fork(src, "intellect", "Aristotelian mind");
    var out = std.ArrayList(@import("../src/common/schema.zig").Relation).init(allocator);
    defer out.deinit();
    try cs.relationsFrom(fork_id, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
}

test "catalog ingest and viewer pagination" {
    const allocator = std.testing.allocator;
    var seq = IdSequence.init();
    var cat = Catalog.init(allocator, &seq);
    defer cat.deinit();

    const body = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const id   = try cat.ingest(body, .{ .title = "Alphabet", .language = "lat" });
    var v = Viewer.init(allocator, &cat, 10);
    const p0 = v.getPage(id, 0).?;
    try std.testing.expectEqual(@as(usize, 3), p0.total_pages);
    try std.testing.expectEqualStrings("ABCDEFGHIJ", p0.content);
}

test "naming generates unique names" {
    const allocator = std.testing.allocator;
    var seq = IdSequence.init();
    var ns  = NameStore.init(allocator, &seq);
    defer ns.deinit();
    const a = try ns.generateAndStore(.space,  .greek, .archon,   1);
    const b = try ns.generateAndStore(.wizard, .norse, .sovereign, 2);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(usize, 2), ns.count());
}

test "keyword index cross-subsystem" {
    const allocator = std.testing.allocator;
    var ki = KeywordIndex.init(allocator);
    defer ki.deinit();
    try ki.indexDocument(10, "logos eidos nous pneuma");
    try ki.indexDocument(20, "nous and being");
    var out = std.ArrayList(u64).init(allocator);
    defer out.deinit();
    try ki.search("nous", &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
}
