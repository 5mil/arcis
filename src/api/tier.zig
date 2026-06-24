//! tier.zig — Arcis TierDispatcher
//! Phase 13 — updated to dispatch live requests to handlers

const std       = @import("std");
const Allocator = std.mem.Allocator;
const Request   = @import("server.zig").Request;
const Response  = @import("server.zig").Response;
const handlers  = @import("handlers.zig");
const ArcisSession = @import("../dashboard/arcis_session.zig").ArcisSession;

pub const Caps = struct {
    infer:     bool = false,
    rag:       bool = false,
    agents:    bool = false,
    workflow:  bool = false,
    media:     bool = false,
    ontology:  bool = false,
    naming:    bool = false,
    dashboard: bool = false,
};

pub const Tier = struct {
    name: []const u8,
    caps: Caps,

    pub fn fromName(name: []const u8) Tier {
        if (std.mem.eql(u8, name, "forma")) return .{
            .name = "forma",
            .caps = .{ .infer = true, .rag = true },
        };
        if (std.mem.eql(u8, name, "figura")) return .{
            .name = "figura",
            .caps = .{ .infer = true, .rag = true, .agents = true, .workflow = true },
        };
        return .{  // visio (default)
            .name = "visio",
            .caps = .{
                .infer = true, .rag = true, .agents = true, .workflow = true,
                .media = true, .ontology = true, .naming = true, .dashboard = true,
            },
        };
    }
};

pub const TierDispatcher = struct {
    tier:    Tier,
    session: *ArcisSession,
    allocator: Allocator,

    pub fn init(allocator: Allocator, session: *ArcisSession, tier_name: []const u8) TierDispatcher {
        return .{
            .tier      = Tier.fromName(tier_name),
            .session   = session,
            .allocator = allocator,
        };
    }

    pub fn dispatch(self: *TierDispatcher, allocator: Allocator, req: *Request) !Response {
        const path = req.path;

        if (std.mem.eql(u8, path, "/health") or std.mem.startsWith(u8, path, "/health?"))
            return handlers.handleHealth(allocator, req, self.session);

        if (std.mem.eql(u8, path, "/infer"))
            return handlers.handleInfer(allocator, req, self.session);

        if (std.mem.eql(u8, path, "/rag"))
            return handlers.handleRag(allocator, req, self.session);

        if (std.mem.eql(u8, path, "/search") or std.mem.startsWith(u8, path, "/search?"))
            return handlers.handleSearch(allocator, req, self.session);

        if (std.mem.eql(u8, path, "/name"))
            return handlers.handleName(allocator, req, self.session);

        if (std.mem.eql(u8, path, "/workflow/run"))
            return handlers.handleWorkflowRun(allocator, req, self.session);

        if (std.mem.eql(u8, path, "/term/propose"))
            return handlers.handleTermPropose(allocator, req, self.session);

        if (std.mem.eql(u8, path, "/term/validate"))
            return handlers.handleTermValidate(allocator, req, self.session);

        // 404
        const body = try allocator.dupe(u8, "{\"error\":\"not found\"}");
        return Response{ .status = 404, .body = body, .allocator = allocator };
    }
};
