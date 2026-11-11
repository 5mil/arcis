//! Melos GLM-5.3-Flash planner wiring.
//! Uses Arcis’s existing GGUF Session (src/infer/session.zig) as the backend.
//!
//! Recommended model:
//!   unsloth/GLM-5.3-Flash-GGUF  (MIT, hybrid sparse+linear attention, 320B-A18B)
//!   Prefer UD-IQ3_XXS / UD-Q4_K_XL or similar depending on available RAM/VRAM.
//!
//! Note: Arcis’s current transformer may need architecture extensions
//! (hybrid attention, MoE routing, mHC) before full native speed.
//! Until then this layer provides the clean interface and config so the
//! Melos agent can call Session.generate() once the model loads.

const std = @import("std");
const Session = @import("../../infer/session.zig").Session;

/// Configuration for the Melos GLM planner.
pub const GlmPlannerConfig = struct {
    /// Path to the first GGUF shard (or single file).
    model_path: []const u8,
    /// Max new tokens per generation turn.
    max_tokens: usize = 2048,
    /// Optional system / tool-description prefix injected before the user task.
    system_prefix: []const u8 =
        \\You are the Melos music agent inside Arcis.
        \\You plan and call tools to understand and generate symbolic music.
        \\Available tools: melos.generate, melos.analyze, melos.echo.
        \\Respond with clear reasoning and tool calls when needed.
        \\,
    seed: u64 = 42,
};

/// Thin wrapper that turns a loaded Arcis Session into a Melos planner.
pub const GlmPlanner = struct {
    session: *Session,
    cfg: GlmPlannerConfig,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        session: *Session,
        cfg: GlmPlannerConfig,
    ) GlmPlanner {
        return .{
            .session = session,
            .cfg = cfg,
            .allocator = allocator,
        };
    }

    /// Run a planning / generation turn.
    /// Caller owns the returned slice.
    pub fn plan(self: *GlmPlanner, task: []const u8) ![]u8 {
        var prompt = std.ArrayList(u8).init(self.allocator);
        defer prompt.deinit();

        try prompt.appendSlice(self.cfg.system_prefix);
        try prompt.appendSlice("\n\nUser task:\n");
        try prompt.appendSlice(task);
        try prompt.appendSlice("\n\nAssistant:");

        // Stop on common EOS-like tokens; real stop set comes from tokenizer later.
        const stop: []const u32 = &.{};
        return try self.session.generate(prompt.items, self.cfg.max_tokens, stop);
    }
};

// ---------------------------------------------------------------------------
// Wiring sketch (inside Arcis session init, once GGUF loader supports the model):
//
// const glm_cfg = GlmPlannerConfig{
//     .model_path = "models/GLM-5.3-Flash-UD-IQ3_XXS.gguf",
// };
// // ... load tokenizer + weights via existing src/infer/loader.zig ...
// var session = try Session.init(allocator, tokenizer, weights, tcfg, scfg, glm_cfg.seed);
// var planner = GlmPlanner.init(allocator, &session, glm_cfg);
// const plan = try planner.plan("Generate a calm A-minor verse with piano and soft drums");
//
