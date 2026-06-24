//! server.zig — Arcis HTTP server
//! Phase 13 — Live TCP accept loop wired to TierDispatcher
//! Listens on 127.0.0.1:<port>, reads HTTP/1.1 request line, dispatches to handler.

const std = @import("std");
const Allocator     = std.mem.Allocator;
const net           = std.net;
const TierDispatcher = @import("tier.zig").TierDispatcher;
const handlers      = @import("handlers.zig");

pub const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16        = 8080,
    backlog: u31     = 128,
};

pub const Method = enum { GET, POST, DELETE, UNKNOWN };

pub const Request = struct {
    method:  Method,
    path:    []const u8,
    body:    []const u8,
    allocator: Allocator,

    pub fn deinit(self: *Request) void {
        self.allocator.free(self.body);
    }
};

pub const Response = struct {
    status:  u16          = 200,
    body:    []const u8   = "",
    allocator: Allocator,

    pub fn deinit(self: *Response) void {
        if (self.body.len > 0) self.allocator.free(self.body);
    }
};

pub const Server = struct {
    config:     ServerConfig,
    dispatcher: *TierDispatcher,
    allocator:  Allocator,

    pub fn init(allocator: Allocator, dispatcher: *TierDispatcher, config: ServerConfig) Server {
        return .{ .config = config, .dispatcher = dispatcher, .allocator = allocator };
    }

    /// Blocking accept loop. Call from main after ArcisSession.init.
    pub fn serve(self: *Server) !void {
        const addr = try net.Address.parseIp4(self.config.host, self.config.port);
        var listener = try addr.listen(.{ .reuse_address = true, .kernel_backlog = self.config.backlog });
        defer listener.deinit();

        std.log.info("Arcis listening on {s}:{d}", .{ self.config.host, self.config.port });

        while (true) {
            const conn = try listener.accept();
            // Spawn a detached thread per connection.
            const ctx = try self.allocator.create(ConnContext);
            ctx.* = .{ .conn = conn, .server = self };
            const t = try std.Thread.spawn(.{}, handleConn, .{ctx});
            t.detach();
        }
    }
};

const ConnContext = struct {
    conn:   net.Server.Connection,
    server: *Server,
};

fn handleConn(ctx: *ConnContext) void {
    defer ctx.server.allocator.destroy(ctx);
    defer ctx.conn.stream.close();
    serveConn(ctx) catch |err| {
        std.log.err("connection error: {}", .{err});
    };
}

fn serveConn(ctx: *ConnContext) !void {
    const allocator = ctx.server.allocator;
    var buf: [4096]u8 = undefined;
    const n = try ctx.conn.stream.read(&buf);
    if (n == 0) return;
    const raw = buf[0..n];

    // Parse request line: "METHOD /path HTTP/1.1\r\n"
    var lines = std.mem.splitSequence(u8, raw, "\r\n");
    const request_line = lines.next() orelse return;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method_str = parts.next() orelse "";
    const path        = parts.next() orelse "/";

    const method: Method = if (std.mem.eql(u8, method_str, "GET")) .GET
        else if (std.mem.eql(u8, method_str, "POST")) .POST
        else if (std.mem.eql(u8, method_str, "DELETE")) .DELETE
        else .UNKNOWN;

    // Extract body (after double CRLF).
    const body = if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |idx|
        try allocator.dupe(u8, raw[idx + 4 ..])
    else
        try allocator.dupe(u8, "");

    var req = Request{ .method = method, .path = path, .body = body, .allocator = allocator };
    defer req.deinit();

    var resp = try ctx.server.dispatcher.dispatch(allocator, &req);
    defer resp.deinit();

    // Write HTTP/1.1 response.
    const status_text: []const u8 = switch (resp.status) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        else => "Internal Server Error",
    };
    const header = try std.fmt.allocPrint(allocator,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ resp.status, status_text, resp.body.len },
    );
    defer allocator.free(header);
    try ctx.conn.stream.writeAll(header);
    try ctx.conn.stream.writeAll(resp.body);
}
