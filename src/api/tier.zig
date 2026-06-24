//! tier.zig — Forma / Figura / Visio tier dispatcher: route requests by capability tier
//! Phase 11 — src/api/
//! Tiers defined in v0.1.0 and zigllm-ui: Forma (basic), Figura (standard), Visio (full)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Request   = @import("server.zig").Request;
const Response  = @import("server.zig").Response;
const Status    = @import("server.zig").Status;
const Router    = @import("server.zig").Router;
const Route     = @import("server.zig").Route;
const Method    = @import("server.zig").Method;

// ---------------------------------------------------------------------------
// Tier definition
// ---------------------------------------------------------------------------

pub const Tier = enum {
    forma,   // text inference + RAG only
    figura,  // + agents + workflow
    visio,   // + media pipelines + ontology + naming + dashboard
};

/// Capability bitmask per tier.
pub const TierCapabilities = struct {
    infer:    bool,
    rag:      bool,
    agents:   bool,
    workflow: bool,
    media:    bool,
    ontology: bool,
    naming:   bool,
    dashboard: bool,

    pub fn forTier(t: Tier) TierCapabilities {
        return switch (t) {
            .forma => .{
                .infer = true,  .rag = true,
                .agents = false, .workflow = false, .media = false,
                .ontology = false, .naming = false, .dashboard = false,
            },
            .figura => .{
                .infer = true,  .rag = true,
                .agents = true, .workflow = true, .media = false,
                .ontology = false, .naming = false, .dashboard = false,
            },
            .visio => .{
                .infer = true,  .rag = true,
                .agents = true, .workflow = true, .media = true,
                .ontology = true, .naming = true, .dashboard = true,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// TierDispatcher
// ---------------------------------------------------------------------------

pub const TierDispatcher = struct {
    tier:      Tier,
    caps:      TierCapabilities,
    routers:   [3]Router,   // index = @intFromEnum(Tier)
    allocator: Allocator,

    pub fn init(allocator: Allocator, tier: Tier) TierDispatcher {
        return .{
            .tier      = tier,
            .caps      = TierCapabilities.forTier(tier),
            .routers   = .{
                Router.init(allocator),
                Router.init(allocator),
                Router.init(allocator),
            },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TierDispatcher) void {
        for (&self.routers) |*r| r.deinit();
    }

    /// Register a route for a specific tier (and all tiers above it).
    pub fn addRoute(self: *TierDispatcher, min_tier: Tier, route: Route) !void {
        const min_idx = @intFromEnum(min_tier);
        for (min_idx..3) |i| {
            try self.routers[i].add(route);
        }
    }

    /// Dispatch a request through the active tier's router.
    pub fn dispatch(self: *TierDispatcher, req: *Request) !Response {
        const idx = @intFromEnum(self.tier);
        return try self.routers[idx].dispatch(req);
    }

    /// Check if the active tier has a capability.
    pub fn has(self: TierDispatcher, comptime field: []const u8) bool {
        return @field(self.caps, field);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TierCapabilities forma" {
    const caps = TierCapabilities.forTier(.forma);
    try std.testing.expect(caps.infer);
    try std.testing.expect(!caps.agents);
    try std.testing.expect(!caps.media);
}

test "TierCapabilities visio has all" {
    const caps = TierCapabilities.forTier(.visio);
    try std.testing.expect(caps.infer and caps.rag and caps.agents and
        caps.workflow and caps.media and caps.ontology and caps.naming and caps.dashboard);
}
