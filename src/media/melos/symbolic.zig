//! Melos step 3 — Symbolic understanding foundation.
//! Lightweight structures for analyzing and indexing SymbolicPiece data.
//! MusicBERT-style embeddings and CLaMP-style alignment come later;
//! this provides the data model and simple analytic helpers.

const std = @import("std");
const types = @import("types.zig");

/// Compact symbolic summary used for retrieval and conditioning.
pub const SymbolicSummary = struct {
    key: ?types.Key = null,
    tempo_bpm: ?f32 = null,
    emotion: ?types.Emotion = null,
    density: f32 = 0.0,          // notes per beat
    pitch_mean: f32 = 60.0,
    pitch_std: f32 = 0.0,
    track_roles: std.EnumSet(types.TrackRole) = .{},
    bar_count: u16 = 0,
};

/// Analyze a SymbolicPiece into a summary (rule-based v1).
pub fn summarize(piece: *const types.SymbolicPiece) SymbolicSummary {
    var sum = SymbolicSummary{
        .key = piece.attributes.key,
        .tempo_bpm = piece.attributes.tempo_bpm,
        .emotion = piece.attributes.emotion,
        .bar_count = piece.attributes.bars orelse 0,
    };

    var note_count: usize = 0;
    var pitch_sum: f32 = 0;
    var pitch_sq: f32 = 0;
    var total_ticks: u32 = 0;

    for (piece.tracks) |track| {
        sum.track_roles.insert(track.role);
        for (track.events) |note| {
            note_count += 1;
            const p = @as(f32, @floatFromInt(note.pitch));
            pitch_sum += p;
            pitch_sq += p * p;
            total_ticks = @max(total_ticks, note.start_tick + note.duration_ticks);
        }
    }

    if (note_count > 0) {
        sum.pitch_mean = pitch_sum / @as(f32, @floatFromInt(note_count));
        const variance = (pitch_sq / @as(f32, @floatFromInt(note_count))) - (sum.pitch_mean * sum.pitch_mean);
        sum.pitch_std = @sqrt(@max(variance, 0.0));
        // Rough density: notes per quarter note (assuming 480 ticks/quarter)
        const quarters = @as(f32, @floatFromInt(total_ticks)) / 480.0;
        if (quarters > 0) sum.density = @as(f32, @floatFromInt(note_count)) / quarters;
    }

    return sum;
}

/// Simple retrieval key for later indexing (MusicBERT / CLaMP placeholder).
pub const RetrievalKey = struct {
    summary: SymbolicSummary,
    /// Future: embedding vector from a symbolic encoder.
    embedding: ?[]f32 = null,

    pub fn deinit(self: *RetrievalKey, allocator: std.mem.Allocator) void {
        if (self.embedding) |e| allocator.free(e);
    }
};

/// Build a retrieval key from a piece.
pub fn makeRetrievalKey(piece: *const types.SymbolicPiece) RetrievalKey {
    return .{
        .summary = summarize(piece),
        .embedding = null, // filled by future encoder
    };
}

// ---------------------------------------------------------------------------
// Next (step 3 continued):
// - Add a lightweight symbolic encoder interface.
// - Build an in-memory index of RetrievalKey for agent search.
// - Later: MusicBERT-style pretraining or CLaMP contrastive alignment.
//
