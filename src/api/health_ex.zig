const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = @import("server.zig").Request;
const Response = @import("server.zig").Response;
const ArcisSession = @import("dashboard").ArcisSession;

pub fn run(allocator: Allocator, _: *Request, session: *ArcisSession) !Response {
    const loaded = if (session.infer.loaded) "true" else "false";
    // Zig 0.16: std.fs.cwd removed; library presence is reported via catalog count.
    const lib = if (session.library.count() > 0) "true" else "false";
    const body = try std.fmt.allocPrint(allocator,
        "{{\"status\":\"ok\",\"model_loaded\":{s},\"library\":{s}}}", .{ loaded, lib });
    return Response{ .status = 200, .body = body, .allocator = allocator };
}
