//! Melos runtime configuration and CLI flag support.
//! Integrates with Arcis core Config.

const std = @import("std");

/// Melos-specific settings, including the GLM-5.3-Flash planner path.
pub const MelosConfig = struct {
    /// Path to GLM-5.3-Flash (or other) GGUF for the Melos planner.
    /// Set via --melos-model <path> or environment.
    planner_model_path: ?[]const u8 = null,

    /// Max tokens for a single planner turn.
    planner_max_tokens: usize = 2048,

    /// Enable Melos agent tools by default.
    enable_tools: bool = true,

    pub fn default() MelosConfig {
        return .{};
    }

    /// Parse --melos-model and related flags from argv.
    /// Call early in main; returns owned slices that must be freed by caller if desired.
    pub fn fromArgs(allocator: std.mem.Allocator, args: []const []const u8) !MelosConfig {
        var cfg = MelosConfig.default();
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--melos-model") and i + 1 < args.len) {
                cfg.planner_model_path = try allocator.dupe(u8, args[i + 1]);
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--melos-max-tokens") and i + 1 < args.len) {
                cfg.planner_max_tokens = std.fmt.parseInt(usize, args[i + 1], 10) catch 2048;
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--no-melos-tools")) {
                cfg.enable_tools = false;
            }
        }
        return cfg;
    }
};
