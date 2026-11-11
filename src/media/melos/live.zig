//! Melos live performance session.
//! Streaming / live mode that keeps the existing architecture:
//! SymbolicPiece, MusicAttributes, agent tools, GLM planner, generation stub.
//! Crowd prompts are turned into attribute / tone modulations via the Melos agent.

const std = @import("std");
const types = @import("types.zig");
const generate = @import("generate.zig");

/// Current live state (shared with the agent / GUI).
pub const LiveState = struct {
    base_prompt: []const u8,
    attributes: types.MusicAttributes,
    current_tick: u32 = 0,
    density: f32 = 0.4,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LiveState) void {
        self.allocator.free(self.base_prompt);
        self.attributes.deinit(self.allocator);
    }
};

/// One step of live generation: produce the next short bar of notes.
pub fn liveStep(
    allocator: std.mem.Allocator,
    state: *LiveState,
) ![]types.MidiNote {
    var req = generate.GenerateRequest{
        .text = state.base_prompt,
        .attributes = state.attributes,
        .bars = 1,
        .seed = state.current_tick,
    };
    var result = try generate.generateStub(allocator, req);
    defer result.deinit();

    // Shift notes to current_tick and return a copy
    const src = result.piece.tracks[0].events;
    const out = try allocator.alloc(types.MidiNote, src.len);
    for (src, 0..) |note, i| {
        out[i] = note;
        out[i].start_tick += state.current_tick;
    }
    return out;
}

/// Apply a crowd prompt as AI tone modulation.
/// In production this calls the GLM planner / Melos agent to interpret the prompt
/// and return updated MusicAttributes. Here we provide a simple rule-based stub
/// that the real agent can replace.
pub fn modulateFromPrompt(
    allocator: std.mem.Allocator,
    state: *LiveState,
    crowd_prompt: []const u8,
) !types.MusicAttributes {
    var attrs = state.attributes;
    // Simple keyword modulation (replace with agent call)
    if (std.mem.indexOf(u8, crowd_prompt, "bright") != null or
        std.mem.indexOf(u8, crowd_prompt, "happy") != null)
    {
        attrs.emotion = .bright;
        if (attrs.tempo_bpm) |*t| t.* = @min(t.* + 10, 180);
    } else if (std.mem.indexOf(u8, crowd_prompt, "dark") != null or
               std.mem.indexOf(u8, crowd_prompt, "tense") != null)
    {
        attrs.emotion = .dark;
        state.density = @min(state.density + 0.15, 1.0);
    } else if (std.mem.indexOf(u8, crowd_prompt, "soft") != null or
               std.mem.indexOf(u8, crowd_prompt, "calm") != null)
    {
        attrs.emotion = .calm;
        if (attrs.tempo_bpm) |*t| t.* = @max(t.* - 8, 60);
        state.density = @max(state.density - 0.1, 0.1);
    }
    // Future: call GlmPlanner or MelosTool "melos.modulate" here
    _ = allocator;
    return attrs;
}

// ---------------------------------------------------------------------------
// API sketch (to be wired in Arcis HTTP router):
//
// POST /api/melos/live/step
//   body: { base_prompt, tempo_bpm, density, current_tick }
//   → { notes: [MidiNote] }
//
// POST /api/melos/live/modulate
//   body: { prompt }
//   → { summary, tempo_bpm, density, emotion, ... }
//
