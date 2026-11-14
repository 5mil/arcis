//! arcis_session.zig — top-level engine session: wires all subsystems into one handle
//! Phase 11+ — now includes optional InferenceEngine for real GGUF generation

const std = @import("std");
const Allocator = std.mem.Allocator;

// Subsystem imports via named modules (resolves even when this file is a test root)
const common       = @import("../common/root.zig");
const IdSequence    = common.IdSequence;
const ontology      = @import("../ontology/root.zig");
const ConceptStore  = ontology.ConceptStore;
const TermDir       = ontology.TerminologyDirectory;
const library       = @import("../library/root.zig");
const Catalog       = library.Catalog;
const Viewer        = library.Viewer;
const NameStore     = @import("../naming/root.zig").NameStore;
const UnifiedSearch = @import("../search/index.zig").UnifiedSearchIndex;
const WorkflowSession = @import("../workflow/root.zig").WorkflowSession;
const TierDispatcher = @import("../api/tier.zig").TierDispatcher;
const ViewBuilder   = @import("views.zig").ViewBuilder;
const InferenceEngine = @import("../infer/engine.zig").InferenceEngine;

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
    infer:      InferenceEngine,
    allocator:  Allocator,

    /// Initialise the full engine. tier_name: "forma" | "figura" | "visio".
    pub fn init(allocator: Allocator, tier_name: []const u8) !ArcisSession {
        var seq        = IdSequence.init();
        var concepts   = ConceptStore.init(allocator, &seq);
        const terms    = TermDir.init(allocator, &concepts);
        const catalog  = Catalog.init(allocator, &seq);
        const names    = NameStore.init(allocator, &seq);
        const search   = UnifiedSearch.init(allocator);
        const workflow = WorkflowSession.init(allocator);
        const tier_d   = TierDispatcher.init(allocator, null, tier_name);
        const views    = ViewBuilder.init(allocator);
        const infer    = InferenceEngine.initEmpty(allocator);

        var session = ArcisSession{
            .seq      = seq,
            .concepts = concepts,
            .terms    = terms,
            .catalog  = catalog,
            .names    = names,
            .search   = search,
            .workflow = workflow,
            .tier     = tier_d,
            .views    = views,
            .infer    = infer,
            .allocator = allocator,
        };
        session.tier.setSession(&session);
        return session;
    }

    /// Load a GGUF model for inference. Optional — engine works without it.
    pub fn loadModel(self: *ArcisSession, path: []const u8) !void {
        try self.infer.load(path);
    }

    pub fn deinit(self: *ArcisSession) void {
        self.infer.deinit();
        self.concepts.deinit();
        self.catalog.deinit();
        self.names.deinit();
        self.search.deinit();
        self.workflow.deinit();
        // TierDispatcher holds no owned resources
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ArcisSession init visio" {
    const allocator = std.testing.allocator;
    var session = try ArcisSession.init(allocator, "visio");
    defer session.deinit();
    try std.testing.expectEqualStrings("visio", session.tier.tier.name);
    try std.testing.expect(session.tier.tier.caps.media);
    try std.testing.expect(session.tier.tier.caps.naming);
    try std.testing.expect(!session.infer.loaded);
}

test "ArcisSession init forma" {
    const allocator = std.testing.allocator;
    var session = try ArcisSession.init(allocator, "forma");
    defer session.deinit();
    try std.testing.expectEqualStrings("forma", session.tier.tier.name);
    try std.testing.expect(!session.tier.tier.caps.media);
}
