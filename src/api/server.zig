//! server.zig — Arcis HTTP server
//! Phase 13 — Live TCP accept loop wired to TierDispatcher
//! Zig 0.16: std.net removed; use std.Io.net + process.Init.io

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const TierDispatcher = @import("tier.zig").TierDispatcher;
const handlers = @import("handlers.zig");

pub const ServerConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    backlog: u31 = 128,
};

pub const Method = enum { GET, POST, DELETE, UNKNOWN };

pub const Request = struct {
    method: Method,
    path: []const u8,
    body: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *Request) void {
        self.allocator.free(self.body);
    }
};

pub const Response = struct {
    status: u16 = 200,
    body: []const u8 = "",
    allocator: Allocator,

    pub fn deinit(self: *Response) void {
        if (self.body.len > 0) self.allocator.free(self.body);
    }
};

pub const Server = struct {
    config: ServerConfig,
    dispatcher: *TierDispatcher,
    allocator: Allocator,
    io: Io,

    pub fn init(allocator: Allocator, dispatcher: *TierDispatcher, config: ServerConfig, io: Io) Server {
        return .{ .config = config, .dispatcher = dispatcher, .allocator = allocator, .io = io };
    }

    /// Blocking accept loop. Call from main after ArcisSession.init.
    pub fn serve(self: *Server) !void {
        const addr = try net.IpAddress.parse(self.config.host, self.config.port);
        var listener = try addr.listen(self.io, .{ .reuse_address = true });
        defer listener.deinit(self.io);

        std.log.info("Arcis listening on {s}:{d}", .{ self.config.host, self.config.port });

        while (true) {
            const stream = try listener.accept(self.io);
            const ctx = try self.allocator.create(ConnContext);
            ctx.* = .{ .stream = stream, .server = self };
            const t = try std.Thread.spawn(.{}, handleConn, .{ctx});
            t.detach();
        }
    }
};

const ConnContext = struct {
    stream: net.Stream,
    server: *Server,
};

fn handleConn(ctx: *ConnContext) void {
    defer ctx.server.allocator.destroy(ctx);
    defer ctx.stream.close(ctx.server.io);
    serveConn(ctx) catch |err| {
        std.log.err("connection error: {}", .{err});
    };
}

fn serveConn(ctx: *ConnContext) !void {
    const allocator = ctx.server.allocator;
    const io = ctx.server.io;

    var read_buf: [4096]u8 = undefined;
    var reader = ctx.stream.reader(io, &read_buf);
    const n = try reader.interface.read(&read_buf);
    if (n == 0) return;
    const raw = read_buf[0..n];

    // Parse request line: "METHOD /path HTTP/1.1\r\n"
    var lines = std.mem.splitSequence(u8, raw, "\r\n");
    const request_line = lines.next() orelse return;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method_str = parts.next() orelse "";
    const path = parts.next() orelse "/";

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

    const status_text: []const u8 = switch (resp.status) {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        503 => "Service Unavailable",
        else => "Internal Server Error",
    };
    const header = try std.fmt.allocPrint(allocator,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n",
        .{ resp.status, status_text, resp.body.len },
    );
    defer allocator.free(header);

    var write_buf: [512]u8 = undefined;
    var writer = ctx.stream.writer(io, &write_buf);
    try writer.interface.writeAll(header);
    try writer.interface.writeAll(resp.body);
    try writer.interface.flush();
}
