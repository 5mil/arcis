//! server.zig — Arcis HTTP server
//! Phase 13 — Live TCP accept loop wired to TierDispatcher
//! Listens on 0.0.0.0:<port> (all interfaces) for local + cloud/Docker.

const std = @import("std");
const Allocator     = std.mem.Allocator;
const net           = std.net;
const TierDispatcher = @import("tier.zig").TierDispatcher;
const handlers      = @import("handlers.zig");

pub const ServerConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16        = 8080,
    backlog: u31     = 128,
};

/// Hard limits: bounded request size, bounded concurrency, read timeout.
const MAX_REQ: usize = 8192;
const MAX_BODY: usize = 6144;
const MAX_CONNS: u32 = 24;
const READ_TIMEOUT_SEC: i64 = 5;
const THREAD_STACK: usize = 512 * 1024;
var g_active = std.atomic.Value(u32).init(0);

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
            const conn = listener.accept() catch |err| {
                std.log.err("accept failed: {}", .{err});
                std.time.sleep(50 * std.time.ns_per_ms);
                continue;
            };
            // Shed load instead of growing without bound.
            if (g_active.load(.monotonic) >= MAX_CONNS) {
                conn.stream.close();
                continue;
            }
            const tv = std.posix.timeval{ .sec = READ_TIMEOUT_SEC, .usec = 0 };
            std.posix.setsockopt(conn.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
            const ctx = self.allocator.create(ConnContext) catch {
                conn.stream.close();
                continue;
            };
            ctx.* = .{ .conn = conn, .server = self };
            _ = g_active.fetchAdd(1, .monotonic);
            // Detached thread per connection with a small stack.
            const t = std.Thread.spawn(.{ .stack_size = THREAD_STACK }, handleConn, .{ctx}) catch {
                _ = g_active.fetchSub(1, .monotonic);
                self.allocator.destroy(ctx);
                conn.stream.close();
                continue;
            };
            t.detach();
        }
    }
};

const ConnContext = struct {
    conn:   net.Server.Connection,
    server: *Server,
};

fn handleConn(ctx: *ConnContext) void {
    defer _ = g_active.fetchSub(1, .monotonic);
    defer ctx.server.allocator.destroy(ctx);
    defer ctx.conn.stream.close();
    serveConn(ctx) catch |err| {
        std.log.err("connection error: {}", .{err});
    };
}

fn serveConn(ctx: *ConnContext) !void {
    const allocator = ctx.server.allocator;
    var buf: [MAX_REQ]u8 = undefined;
    var total: usize = 0;
    var header_end: ?usize = null;
    var content_len: usize = 0;
    while (true) {
        if (total == buf.len) return sendStatus(ctx, 413, "request too large");
        const n = try ctx.conn.stream.read(buf[total..]);
        if (n == 0) break;
        total += n;
        if (header_end == null) {
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
                header_end = idx + 4;
                content_len = parseContentLength(buf[0..idx]);
                if (content_len > MAX_BODY) return sendStatus(ctx, 413, "request too large");
            }
        }
        if (header_end) |he| if (total >= he + content_len) break;
    }
    if (total == 0) return;
    const raw = buf[0..total];

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

    // Extract body (after double CRLF), never more than Content-Length.
    const body = if (header_end) |he|
        try allocator.dupe(u8, raw[he..@min(raw.len, he + content_len)])
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
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        413 => "Payload Too Large",
        429 => "Too Many Requests",
        405 => "Method Not Allowed",
        503 => "Service Unavailable",
        else => "Internal Server Error",
    };
    const header = try std.fmt.allocPrint(allocator,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n",
        .{ resp.status, status_text, resp.body.len },
    );
    defer allocator.free(header);
    try ctx.conn.stream.writeAll(header);
    try ctx.conn.stream.writeAll(resp.body);
}

fn parseContentLength(headers: []const u8) usize {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    _ = it.next(); // request line
    while (it.next()) |line| {
        if (line.len < 15) continue;
        if (!std.ascii.eqlIgnoreCase(line[0..15], "content-length:")) continue;
        const v = std.mem.trim(u8, line[15..], " \t");
        return std.fmt.parseInt(usize, v, 10) catch 0;
    }
    return 0;
}

fn sendStatus(ctx: *ConnContext, status: u16, msg: []const u8) !void {
    var out: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&out, "{{\"status\":\"error\",\"error\":\"{s}\"}}", .{msg});
    var hdr: [192]u8 = undefined;
    const h = try std.fmt.bufPrint(&hdr, "HTTP/1.1 {d} Error\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, text.len });
    try ctx.conn.stream.writeAll(h);
    try ctx.conn.stream.writeAll(text);
}
