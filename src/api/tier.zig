//! tier.zig — Arcis TierDispatcher
const std       = @import("std");
const Allocator = std.mem.Allocator;
const Request   = @import("server.zig").Request;
const Response  = @import("server.zig").Response;
const handlers  = @import("handlers.zig");
const root_page = @import("root_page.zig");
const rag_scan  = @import("rag_scan.zig");
const health_ex = @import("health_ex.zig");
const ArcisSession = @import("../dashboard/arcis_session.zig").ArcisSession;
const melos_api = @import("../media/melos/api.zig");

pub const Caps = struct {
    infer: bool = false, rag: bool = false, agents: bool = false, workflow: bool = false,
    media: bool = false, ontology: bool = false, naming: bool = false, dashboard: bool = false,
};

pub const Tier = struct {
    name: []const u8,
    caps: Caps,
    pub fn fromName(name: []const u8) Tier {
        if (std.mem.eql(u8, name, "forma")) return .{ .name = "forma", .caps = .{ .infer = true, .rag = true } };
        if (std.mem.eql(u8, name, "figura")) return .{ .name = "figura", .caps = .{ .infer = true, .rag = true, .agents = true, .workflow = true } };
        return .{ .name = "visio", .caps = .{ .infer = true, .rag = true, .agents = true, .workflow = true, .media = true, .ontology = true, .naming = true, .dashboard = true } };
    }
};

pub const TierDispatcher = struct {
    tier: Tier,
    session: ?*ArcisSession = null,
    allocator: Allocator,
    pub fn init(allocator: Allocator, session: ?*ArcisSession, tier_name: []const u8) TierDispatcher {
        return .{ .tier = Tier.fromName(tier_name), .session = session, .allocator = allocator };
    }
    pub fn setSession(self: *TierDispatcher, session: *ArcisSession) void {
        self.session = session;
    }
    pub fn dispatch(self: *TierDispatcher, allocator: Allocator, req: *Request) !Response {
        const path = req.path;
        const session = self.session orelse return error.NoSession;

        // Core routes
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html"))
            return root_page.handleRoot(allocator, req, session);
        if (std.mem.eql(u8, path, "/health") or std.mem.startsWith(u8, path, "/health?"))
            return health_ex.run(allocator, req, session);
        if (std.mem.eql(u8, path, "/infer")) return handlers.handleInfer(allocator, req, session);
        if (std.mem.eql(u8, path, "/rag")) return rag_scan.run(allocator, req, session);
        if (std.mem.eql(u8, path, "/search") or std.mem.startsWith(u8, path, "/search?"))
            return handlers.handleSearch(allocator, req, session);
        if (std.mem.eql(u8, path, "/name")) return handlers.handleName(allocator, req, session);
        if (std.mem.eql(u8, path, "/workflow/run")) return handlers.handleWorkflowRun(allocator, req, session);
        if (std.mem.eql(u8, path, "/term/propose")) return handlers.handleTermPropose(allocator, req, session);
        if (std.mem.eql(u8, path, "/term/validate")) return handlers.handleTermValidate(allocator, req, session);

        // Melos routes (media tier)
        if (std.mem.startsWith(u8, path, "/api/melos/")) {
            if (!self.tier.caps.media) return forbidden(allocator);
            return try dispatchMelos(allocator, req);
        }

        const body = try allocator.dupe(u8, "{\"error\":\"not found\"}");
        return Response{ .status = 404, .body = body, .allocator = allocator };
    }
};

fn forbidden(allocator: Allocator) !Response {
    const body = try allocator.dupe(u8, "{\"error\":\"tier does not permit this capability\"}");
    return Response{ .status = 403, .body = body, .allocator = allocator };
}

fn dispatchMelos(allocator: Allocator, req: *Request) !Response {
    const method: melos_api.Method = switch (req.method) {
        .GET => .get,
        .POST => .post,
        else => .other,
    };
    const auth = melos_api.AuthInfo{
        .cookie = req.cookie,
        .origin = req.origin,
        .referer = req.referer,
        .remote_ip = req.remote_ip,
        .peer_loopback = req.peer_loopback,
    };
    const r = try melos_api.handleWithAuth(allocator, method, req.path, req.body, auth);
    return Response{ .status = r.status, .body = r.body, .set_cookie = r.set_cookie, .cors = r.cors, .allocator = allocator };
}
