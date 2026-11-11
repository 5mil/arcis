//! Melos symbolic encoder and in-memory index (step 3 continued).
//! Lightweight feature extraction + retrieval index for SymbolicPiece.

const std = @import("std");
const types = @import("types.zig");
const symbolic = @import("symbolic.zig");

/// Simple fixed-size feature vector (pitch histogram + rhythm density).
pub const FeatureVector = struct {
    pitch_hist: [12]f32 = [_]f32{0} ** 12, // pitch-class histogram
    density: f32 = 0.0,
    pitch_mean: f32 = 60.0,
    role_mask: u16 = 0, // bitfield of TrackRole

    pub fn toSlice(self: *const FeatureVector) [16]f32 {
        var out: [16]f32 = undefined;
        @memcpy(out[0..12], &self.pitch_hist);
        out[12] = self.density;
        out[13] = self.pitch_mean / 127.0;
        out[14] = @as(f32, @floatFromInt(self.role_mask)) / 255.0;
        out[15] = 0; // reserved
        return out;
    }
};

/// Extract a FeatureVector from a SymbolicPiece.
pub fn encode(piece: *const types.SymbolicPiece) FeatureVector {
    var fv = FeatureVector{};
    var note_count: usize = 0;
    var pitch_sum: f32 = 0;
    var total_ticks: u32 = 0;

    for (piece.tracks) |track| {
        const role_bit: u16 = @as(u16, 1) << @intFromEnum(track.role);
        fv.role_mask |= role_bit;
        for (track.events) |note| {
            note_count += 1;
            const pc = note.pitch % 12;
            fv.pitch_hist[pc] += 1.0;
            pitch_sum += @as(f32, @floatFromInt(note.pitch));
            total_ticks = @max(total_ticks, note.start_tick + note.duration_ticks);
        }
    }

    if (note_count > 0) {
        for (&fv.pitch_hist) |*h| h.* /= @as(f32, @floatFromInt(note_count));
        fv.pitch_mean = pitch_sum / @as(f32, @floatFromInt(note_count));
        const quarters = @as(f32, @floatFromInt(total_ticks)) / 480.0;
        if (quarters > 0) fv.density = @as(f32, @floatFromInt(note_count)) / quarters;
    }

    return fv;
}

/// In-memory index entry.
pub const IndexEntry = struct {
    id: []const u8,
    features: FeatureVector,
    summary: symbolic.SymbolicSummary,
};

/// Simple linear-scan index (replace with ANN later).
pub const SymbolicIndex = struct {
    entries: std.ArrayList(IndexEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SymbolicIndex {
        return .{
            .entries = std.ArrayList(IndexEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SymbolicIndex) void {
        for (self.entries.items) |*e| self.allocator.free(e.id);
        self.entries.deinit();
    }

    pub fn add(self: *SymbolicIndex, id: []const u8, piece: *const types.SymbolicPiece) !void {
        const owned_id = try self.allocator.dupe(u8, id);
        try self.entries.append(.{
            .id = owned_id,
            .features = encode(piece),
            .summary = symbolic.summarize(piece),
        });
    }

    /// Return the closest entry by L2 distance on the feature vector.
    /// Returns null if empty.
    pub fn nearest(self: *const SymbolicIndex, query: FeatureVector) ?IndexEntry {
        if (self.entries.items.len == 0) return null;
        var best_dist: f32 = std.math.floatMax(f32);
        var best: ?IndexEntry = null;
        const q = query.toSlice();
        for (self.entries.items) |e| {
            const v = e.features.toSlice();
            var dist: f32 = 0;
            for (q, v) |a, b| {
                const d = a - b;
                dist += d * d;
            }
            if (dist < best_dist) {
                best_dist = dist;
                best = e;
            }
        }
        return best;
    }
};
