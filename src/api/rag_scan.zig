//! Naive library scan — no embeddings yet.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = @import("server.zig").Request;
const Response = @import("server.zig").Response;
const ArcisSession = @import("../dashboard/arcis_session.zig").ArcisSession;

fn jsonGetString(body: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, needle) orelse return null;
    const val_start = start + needle.len;
    const end = std.mem.indexOfScalarPos(u8, body, val_start, '"') orelse return null;
    return body[val_start..end];
}

pub fn run(allocator: Allocator, req: *Request, _: *ArcisSession) !Response {
    const query = jsonGetString(req.body, "query") orelse "algebra";
    var hits = std.ArrayList(u8).init(allocator);
    defer hits.deinit();
    try hits.appendSlice("{\"query\":\"");
    try hits.appendSlice(query);
    try hits.appendSlice("\",\"files\":[");

    var dir = std.fs.cwd().openDir("data/library", .{ .iterate = true }) catch {
        const body = try allocator.dupe(u8, "{\"result\":\"no data/library — copy OpenStax txt here\"}");
        return Response{ .status = 200, .body = body, .allocator = allocator };
    };
    defer dir.close();

    var it = dir.iterate();
    var first = true;
    var n: usize = 0;
    while (it.next() catch null) |ent| {
        if (ent.kind != .file) continue;
        if (n >= 8) break;
        const name = ent.name;
        if (!first) try hits.appendSlice(",");
        first = false;
        try hits.appendSlice("\"");
        try hits.appendSlice(name);
        try hits.appendSlice("\"");
        n += 1;
    }
    try hits.appendSlice("]}");
    return Response{ .status = 200, .body = try hits.toOwnedSlice(), .allocator = allocator };
}
