// Minimal OpenAI-compatible HTTP server stub for Arcis (Phase 0)
// TODO: Replace with full implementation (std.http.Server or zap/mio)

const std = @import("std");
const inference = @import("inference.zig");

pub fn startServer(allocator: std.mem.Allocator, port: u16) !void {
    std.log.info("Starting stub OpenAI-compatible server on port {}", .{port});

    // Placeholder server loop
    // In production: use std.http.Server, handle /v1/chat/completions, /v1/models, streaming, etc.
    while (true) {
        std.time.sleep(1 * std.time.ns_per_s);
        // TODO: Accept connections, parse JSON, call inference.infer(), return OpenAI format
    }
}

// Example handler stub (to be expanded)
pub fn handleChatCompletions(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    _ = body;
    const resp = try inference.infer(allocator, .{ .prompt = "Hello" });
    defer allocator.free(resp.text);

    return try std.fmt.allocPrint(allocator,
        \{{
        \  "id": "chatcmpl-stub",
        \  "object": "chat.completion",
        \  "created": {},
        \  "model": "arcis-stub",
        \  "choices": [{{
        \    "index": 0,
        \    "message": {{
        \      "role": "assistant",
        \      "content": "{s}"
        \    }},
        \    "finish_reason": "{s}"
        \  }}]
        \}}
    , .{ std.time.timestamp(), resp.text, resp.finish_reason });
}
