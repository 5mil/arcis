// Minimal inference stub for Arcis (Phase 0)
// TODO: Replace with real GGUF loader + inference engine

const std = @import("std");

pub const InferenceError = error{
    ModelNotLoaded,
    InferenceFailed,
};

pub const ModelConfig = struct {
    path: []const u8,
    tier: []const u8 = "visio",
};

pub const InferenceRequest = struct {
    prompt: []const u8,
    max_tokens: u32 = 256,
    temperature: f32 = 0.7,
};

pub const InferenceResponse = struct {
    text: []const u8,
    tokens: u32,
    finish_reason: []const u8 = "stop",
};

pub fn loadModel(allocator: std.mem.Allocator, config: ModelConfig) !void {
    // TODO: Implement real GGUF loading (use llama.cpp bindings or pure Zig)
    std.log.info("Loading model from {s} for tier {s}", .{ config.path, config.tier });
    // Placeholder: assume success
}

pub fn infer(allocator: std.mem.Allocator, req: InferenceRequest) !InferenceResponse {
    // TODO: Real inference here
    const response_text = try std.fmt.allocPrint(allocator, "[STUB] Response to: {s}", .{req.prompt});
    return InferenceResponse{
        .text = response_text,
        .tokens = @intCast(req.prompt.len / 4),
    };
}

pub fn unloadModel() void {
    // TODO: Cleanup
}
