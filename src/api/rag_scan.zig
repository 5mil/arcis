//! Naive library scan — no embeddings yet.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Request = @import("server.zig").Request;
const Response = @import("server.zig").Response;
const ArcisSession = @import("dashboard").ArcisSession;

fn jsonGetString(body: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, needle) orelse return null;
    const val_start = start + needle.len;
    const end = std.mem.indexOfScalarPos(u8, body, val_start, '"') orelse return null;
    return body[val_start..end];
}

pub fn run(allocator: Allocator, req: *Request, session: *ArcisSession) !Response {
    const query = jsonGetString(req.body, "query") orelse "algebra";
    _ = session;
    // Zig 0.16: std.fs.cwd removed — return stub until Io.Dir scan is wired.
    const body = try std.fmt.allocPrint(allocator,
        "{{\"query\":\"{s}\",\"files\":[],\"note\":\"library scan needs Io.Dir in 0.16\"}}", .{query});
    return Response{ .status = 200, .body = body, .allocator = allocator };
}
