const Allocator = @import("std").mem.Allocator;
const Request = @import("server.zig").Request;
const Response = @import("server.zig").Response;
const ArcisSession = @import("dashboard").ArcisSession;

// Inline minimal index until build system embeds static assets.
const index_html =
    \\<!DOCTYPE html><html><head><meta charset="utf-8"/><title>Arcis</title></head>
    \\<body><h1>Arcis</h1><p>Inference engine API</p>
    \\<p>Routes: /health /infer /rag /search</p></body></html>
;

pub fn handleRoot(allocator: Allocator, _: *Request, _: *ArcisSession) !Response {
    const body = try allocator.dupe(u8, index_html);
    return Response{ .status = 200, .body = body, .allocator = allocator };
}
