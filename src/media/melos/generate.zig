//! Melos step 4 — Text-to-symbolic generation interface.
//! MuseCoco / GETMusic-inspired pipeline: text or attributes → SymbolicPiece.
//! Real model backends come later; this defines the contract and a simple rule-based stub.

const std = @import("std");
const types = @import("types.zig");

/// Generation request.
pub const GenerateRequest = struct {
    text: ?[]const u8 = null,
    attributes: ?types.MusicAttributes = null,
    mask: ?types.TrackMask = null,
    bars: u16 = 8,
    seed: u64 = 42,
};

/// Generation result.
pub const GenerateResult = struct {
    piece: types.SymbolicPiece,
    /// Optional trace from the planner / model.
    trace: ?[]const u8 = null,

    pub fn deinit(self: *GenerateResult) void {
        self.piece.deinit();
        // trace ownership depends on caller
    }
};

/// Stub generator that creates a simple monophonic melody from attributes.
/// Useful for testing the agent loop before a real model is attached.
pub fn generateStub(
    allocator: std.mem.Allocator,
    req: GenerateRequest,
) !GenerateResult {
    var attrs = req.attributes orelse types.MusicAttributes{};
    if (attrs.bars == null) attrs.bars = req.bars;
    if (attrs.tempo_bpm == null) attrs.tempo_bpm = 120.0;

    const bars = attrs.bars orelse req.bars;
    const notes_per_bar: usize = 4;
    const total_notes = bars * notes_per_bar;

    const events = try allocator.alloc(types.MidiNote, total_notes);
    var tick: u32 = 0;
    const ticks_per_quarter: u32 = 480;
    var rng = std.Random.DefaultPrng.init(req.seed);
    const random = rng.random();

    for (events, 0..) |*note, i| {
        const base: u8 = if (attrs.key) |k| @as(u8, k.tonic) + 60 else 60;
        note.* = .{
            .pitch = base + @as(u8, @intCast(random.intRangeAtMost(u8, 0, 12))),
            .velocity = 80,
            .start_tick = tick,
            .duration_ticks = ticks_per_quarter,
            .channel = 0,
        };
        tick += ticks_per_quarter;
        _ = i;
    }

    const track = types.MidiTrack{
        .name = try allocator.dupe(u8, "melody"),
        .role = .melody,
        .program = 0,
        .events = events,
        .allocator = allocator,
    };

    const tracks = try allocator.alloc(types.MidiTrack, 1);
    tracks[0] = track;

    const piece = types.SymbolicPiece{
        .attributes = attrs,
        .tracks = tracks,
        .ticks_per_quarter = 480,
        .allocator = allocator,
    };

    return GenerateResult{
        .piece = piece,
        .trace = null,
    };
}

// ---------------------------------------------------------------------------
// Agent tool integration sketch:
//
// fn generateTool(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
//     // parse input as JSON → GenerateRequest
//     var req = GenerateRequest{ .text = input };
//     var result = try generateStub(allocator, req);
//     defer result.deinit();
//     // serialize piece to JSON and return
//     return try std.fmt.allocPrint(allocator, "generated {d} notes", .{result.piece.tracks[0].events.len});
// }
//
