//! arcis_session.zig — top-level engine session: wires all subsystems into one handle
//! Phase 11 — src/dashboard/
//! This is the single root object created by main.zig and handed to the API server.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Subsystem imports
const IdSequence    = @import("../common/id.zig").IdSequence;
const ConceptStore  = @import("../ontology/concept_store.zig").ConceptStore;
const TermDir       = @import("../ontology/terminology.zig").TerminologyDirectory;
const Catalog       = @import("../library/catalog.zig").Catalog;
const Viewer        = @import("../library/viewer.zig").Viewer;
const NameStore     = @import("../naming/name_store.zig").NameStore;
const UnifiedSearch = @import("../search/index.zig").UnifiedSearchIndex;
const WorkflowSession = @import("../workflow/workflow_session.zig").WorkflowSession;
const TierDispatcher = @import("../api/tier.zig").TierDispatcher;
const Tier          = @import("../api/tier.zig").Tier;
const ViewBuilder   = @import("views.zig").ViewBuilder;

// ---------------------------------------------------------------------------
// ArcisSession
// ---------------------------------------------------------------------------

pub const ArcisSession = struct {
    seq:        IdSequence,
    concepts:   ConceptStore,
    terms:      TermDir,
    catalog:    Catalog,
    names:      NameStore,
    search:     UnifiedSearch,
    workflow:   WorkflowSession,
    tier:       TierDispatcher,
    views:      ViewBuilder,
    allocator:  Allocator,

    /// Initialise the full engine. tier_name: "forma" | "figura" | "visio".
    pub fn init(allocator: Allocator, tier_name: []const u8) !ArcisSession {
        const tier: Tier = if (std.mem.eql(u8, tier_name, "forma")) .forma
            else if (std.mem.eql(u8, tier_name, "figura")) .figura
            else .visio;

        var seq      = IdSequence.init();
        var concepts = ConceptStore.init(allocator, &seq);
        var terms    = TermDir.init(allocator, &concepts);
        var catalog  = Catalog.init(allocator, &seq);
        var names    = NameStore.init(allocator, &seq);
        var search   = UnifiedSearch.init(allocator);
        var workflow = WorkflowSession.init(allocator);
        var tier_d   = TierDispatcher.init(allocator, tier);
        var views    = ViewBuilder.init(allocator);

        return ArcisSession{
            .seq      = seq,
            .concepts = concepts,
            .terms    = terms,
            .catalog  = catalog,
            .names    = names,
            .search   = search,
            .workflow = workflow,
            .tier     = tier_d,
            .views    = views,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ArcisSession) void {
        self.concepts.deinit();
        self.catalog.deinit();
        self.names.deinit();
        self.search.deinit();
        self.workflow.deinit();
        self.tier.deinit();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ArcisSession init visio" {
    const allocator = std.testing.allocator;
    var session = try ArcisSession.init(allocator, "visio");
    defer session.deinit();
    try std.testing.expectEqual(Tier.visio, session.tier.tier);
    try std.testing.expect(session.tier.caps.media);
    try std.testing.expect(session.tier.caps.naming);
}

test "ArcisSession init forma" {
    const allocator = std.testing.allocator;
    var session = try ArcisSession.init(allocator, "forma");
    defer session.deinit();
    try std.testing.expectEqual(Tier.forma, session.tier.tier);
    try std.testing.expect(!session.tier.caps.media);
}
