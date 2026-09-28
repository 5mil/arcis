const Allocator = @import("std").mem.Allocator;
const Request = @import("server.zig").Request;
const Response = @import("server.zig").Response;
const ArcisSession = @import("../dashboard/arcis_session.zig").ArcisSession;
const index_html = @embedFile("../dashboard/static_index.html");

pub fn handleRoot(allocator: Allocator, _: *Request, _: *ArcisSession) !Response {
    const body = try allocator.dupe(u8, index_html);
    return Response{ .status = 200, .body = body, .allocator = allocator, .content_type = "text/html" };
}
