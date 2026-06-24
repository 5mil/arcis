//! server.zig — HTTP/WebSocket server: route table, request/response types, listener loop
//! Phase 11 — src/api/
//! Mirrors: src/workflow/workflow_session.zig (unified session dispatch)

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// HTTP method and status
// ---------------------------------------------------------------------------

pub const Method = enum { GET, POST, PUT, DELETE, PATCH };

pub const Status = enum(u16) {
    ok           = 200,
    created      = 201,
    bad_request  = 400,
    not_found    = 404,
    internal_err = 500,
};

// ---------------------------------------------------------------------------
// Request / Response
// ---------------------------------------------------------------------------

pub const Request = struct {
    method:  Method,
    path:    []const u8,
    headers: std.StringHashMap([]const u8),
    body:    []const u8,
    allocator: Allocator,

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }
};

pub const Response = struct {
    status:  Status,
    body:    []const u8,   // owned by handler
    headers: std.StringHashMap([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, status: Status, body: []const u8) !Response {
        var headers = std.StringHashMap([]const u8).init(allocator);
        try headers.put("Content-Type", "application/json");
        return Response{ .status = status, .body = body, .headers = headers, .allocator = allocator };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
    }
};

// ---------------------------------------------------------------------------
// Route handler type
// ---------------------------------------------------------------------------

pub const HandlerFn = *const fn (req: *Request, allocator: Allocator) anyerror!Response;

pub const Route = struct {
    method:  Method,
    path:    []const u8,   // exact match for now; prefix/regex in Phase 12
    handler: HandlerFn,
};

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

pub const Router = struct {
    routes:    std.ArrayList(Route),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Router {
        return .{ .routes = std.ArrayList(Route).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit();
    }

    pub fn add(self: *Router, route: Route) !void {
        try self.routes.append(route);
    }

    pub fn dispatch(self: *Router, req: *Request) !Response {
        for (self.routes.items) |r| {
            if (r.method == req.method and std.mem.eql(u8, r.path, req.path)) {
                return try r.handler(req, req.allocator);
            }
        }
        return try Response.init(req.allocator, .not_found, "{\"error\":\"not found\"}");
    }
};

// ---------------------------------------------------------------------------
// Server (TCP listener stub)
// ---------------------------------------------------------------------------

pub const ServerConfig = struct {
    host:    []const u8 = "127.0.0.1",
    port:    u16        = 8080,
    threads: usize      = 4,
};

pub const Server = struct {
    config:    ServerConfig,
    router:    Router,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: ServerConfig) Server {
        return .{
            .config    = config,
            .router    = Router.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
    }

    /// Start listening. Blocks until stop() is called.
    /// TODO: std.net.StreamServer accept loop + thread pool dispatch.
    pub fn listen(self: *Server) !void {
        std.log.info("Arcis API listening on {s}:{d}", .{ self.config.host, self.config.port });
        // TODO: open TCP socket, accept connections, parse HTTP/1.1, dispatch to router.
        _ = self;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Router dispatch not_found" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator);
    defer router.deinit();
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    var req = Request{
        .method = .GET, .path = "/missing",
        .headers = headers, .body = "", .allocator = allocator,
    };
    var resp = try router.dispatch(&req);
    defer resp.deinit();
    try std.testing.expectEqual(Status.not_found, resp.status);
}
