//! test_session.zig — ArcisSession integration: init all tiers, check capabilities
//! Phase 12 — tests/

const std  = @import("std");
const ArcisSession = @import("../src/dashboard/arcis_session.zig").ArcisSession;
const Tier         = @import("../src/api/tier.zig").Tier;

test "ArcisSession visio has all capabilities" {
    const allocator = std.testing.allocator;
    var s = try ArcisSession.init(allocator, "visio");
    defer s.deinit();
    try std.testing.expect(s.tier.caps.infer);
    try std.testing.expect(s.tier.caps.rag);
    try std.testing.expect(s.tier.caps.agents);
    try std.testing.expect(s.tier.caps.workflow);
    try std.testing.expect(s.tier.caps.media);
    try std.testing.expect(s.tier.caps.ontology);
    try std.testing.expect(s.tier.caps.naming);
    try std.testing.expect(s.tier.caps.dashboard);
}

test "ArcisSession forma is restricted" {
    const allocator = std.testing.allocator;
    var s = try ArcisSession.init(allocator, "forma");
    defer s.deinit();
    try std.testing.expect(s.tier.caps.infer);
    try std.testing.expect(s.tier.caps.rag);
    try std.testing.expect(!s.tier.caps.agents);
    try std.testing.expect(!s.tier.caps.media);
    try std.testing.expect(!s.tier.caps.naming);
}

test "ArcisSession figura is middle tier" {
    const allocator = std.testing.allocator;
    var s = try ArcisSession.init(allocator, "figura");
    defer s.deinit();
    try std.testing.expect(s.tier.caps.agents);
    try std.testing.expect(s.tier.caps.workflow);
    try std.testing.expect(!s.tier.caps.media);
    try std.testing.expect(!s.tier.caps.ontology);
}

test "ArcisSession catalog and naming wired" {
    const allocator = std.testing.allocator;
    var s = try ArcisSession.init(allocator, "visio");
    defer s.deinit();
    const text_id = try s.catalog.ingest("In the beginning", .{ .title = "Genesis", .language = "heb" });
    try std.testing.expect(text_id > 0);
    const name_id = try s.names.generateAndStore(.wizard, .greek, .sage, 42);
    try std.testing.expect(name_id > 0);
}
