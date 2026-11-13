const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = @import("server.zig").Request;
const Response = @import("server.zig").Response;
const ArcisSession = @import("../dashboard/arcis_session.zig").ArcisSession;

pub fn run(allocator: Allocator, _: *Request, session: *ArcisSession) !Response {
    const loaded = if (session.infer.loaded) "true" else "false";
    var lib: []const u8 = "false";
    if (std.fs.cwd().openDir("data/library", .{})) |d| {
        var dir = d;
        dir.close();
        lib = "true";
    } else |_| {}
    const body = try std.fmt.allocPrint(allocator,
        "{{\"status\":\"ok\",\"model_loaded\":{s},\"library\":{s}}}", .{ loaded, lib });
    return Response{ .status = 200, .body = body, .allocator = allocator };
}
