//! Melos HTTP route handlers.
//! Wire these into Arcis TierDispatcher / server.
//! Endpoints:
//!   POST /api/melos/generate
//!   POST /api/melos/analyze
//!   POST /api/melos/live/step
//!   POST /api/melos/live/modulate

const std = @import("std");
const types = @import("types.zig");
const generate = @import("generate.zig");
const live = @import("live.zig");
const symbolic = @import("symbolic.zig");

/// Shared live session (single-user demo; replace with per-connection later).
var g_live: ?live.LiveState = null;
var g_allocator: ?std.mem.Allocator = null;

pub fn initLive(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// POST /api/melos/generate
pub fn handleGenerate(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    // Minimal parse: look for "text" field (real JSON parser later)
    var req = generate.GenerateRequest{ .text = body };
    var result = try generate.generateStub(allocator, req);
    defer result.deinit();
    // Return simple JSON sketch
    return try std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"ok\",\"notes\":{d}}}",
        .{result.piece.tracks[0].events.len},
    );
}

/// POST /api/melos/analyze
pub fn handleAnalyze(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    _ = body;
    return try std.fmt.allocPrint(allocator, "{{\"status\":\"ok\",\"summary\":\"stub\"}}", .{});
}

/// POST /api/melos/live/step
pub fn handleLiveStep(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (g_live == null) {
        // bootstrap
        g_live = live.LiveState{
            .base_prompt = try allocator.dupe(u8, "ambient"),
            .attributes = .{},
            .allocator = allocator,
        };
    }
    var state = &g_live.? ;
    const notes = try live.liveStep(allocator, state);
    defer allocator.free(notes);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"ok\",\"notes\":{d},\"tick\":{d}}}",
        .{ notes.len, state.current_tick },
    );
}

/// POST /api/melos/live/modulate
pub fn handleLiveModulate(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (g_live == null) return error.NoLiveSession;
    var state = &g_live.? ;
    const new_attrs = try live.modulateFromPrompt(allocator, state, body);
    state.attributes = new_attrs;
    return try std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"ok\",\"summary\":\"modulated\",\"tempo\":{d}}}",
        .{state.attributes.tempo_bpm orelse 120},
    );
}

// ---------------------------------------------------------------------------
// Registration sketch (inside Arcis server / tier dispatcher):
//
// router.post("/api/melos/generate", handleGenerate);
// router.post("/api/melos/analyze", handleAnalyze);
// router.post("/api/melos/live/step", handleLiveStep);
// router.post("/api/melos/live/modulate", handleLiveModulate);
//
