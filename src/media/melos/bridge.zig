//! External GLM bridge for Melos.
//! Calls a local llama.cpp / Unsloth OpenAI-compatible server
//! when native Arcis transformer support for hybrid attention is not yet available.

const std = @import("std");

/// Configuration for the external bridge.
pub const BridgeConfig = struct {
    /// Base URL of the OpenAI-compatible server (e.g. http://127.0.0.1:8080).
    base_url: []const u8 = "http://127.0.0.1:8080",
    /// Model name the server expects.
    model: []const u8 = "glm-5.3-flash",
    /// Request timeout in milliseconds.
    timeout_ms: u64 = 120_000,
};

/// Minimal HTTP client sketch for chat completions.
/// In production this would use Arcis’s HTTP stack or std.http.
pub const GlmBridge = struct {
    cfg: BridgeConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cfg: BridgeConfig) GlmBridge {
        return .{ .cfg = cfg, .allocator = allocator };
    }

    /// Send a chat completion request and return the assistant message.
    /// Caller owns the returned slice.
    /// This is a stub that documents the expected contract; real HTTP is left to the engine.
    pub fn chat(self: *GlmBridge, system: []const u8, user: []const u8) ![]u8 {
        // Expected payload (OpenAI format):
        // POST {base_url}/v1/chat/completions
        // {
        //   "model": self.cfg.model,
        //   "messages": [
        //     {"role": "system", "content": system},
        //     {"role": "user", "content": user}
        //   ]
        // }
        //
        // For now return a placeholder so the interface compiles.
        return try std.fmt.allocPrint(
            self.allocator,
            "[bridge stub] system={d} user={d} chars → model {s}",
            .{ system.len, user.len, self.cfg.model },
        );
    }
};

// ---------------------------------------------------------------------------
// Usage:
// var bridge = GlmBridge.init(allocator, .{});
// const reply = try bridge.chat(system_prompt, task);
//
// Start the server with:
//   llama-server -m path/to/GLM-5.3-Flash-*.gguf --port 8080 --jinja
//
