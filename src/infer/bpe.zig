const std = @import("std");
const Vocab = @import("vocab.zig").Vocab;

/// A single BPE merge rule: merge (left, right) → merged token.
pub const MergeRule = struct {
    left:  []const u8,
    right: []const u8,
    merged: []const u8,
    /// Lower rank = higher priority.
    rank: u32,
};

/// BPE merge table: ordered list of merge rules.
pub const MergeTable = struct {
    rules: std.ArrayList(MergeRule),
    /// Fast lookup: "left right" → rank
    pair_rank: std.StringHashMap(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MergeTable {
        return .{
            .rules      = std.ArrayList(MergeRule).init(allocator),
            .pair_rank  = std.StringHashMap(u32).init(allocator),
            .allocator  = allocator,
        };
    }

    pub fn deinit(self: *MergeTable) void {
        for (self.rules.items) |r| {
            self.allocator.free(r.left);
            self.allocator.free(r.right);
            self.allocator.free(r.merged);
        }
        self.rules.deinit();
        // pair_rank keys are slices into rule strings, freed above.
        self.pair_rank.deinit();
    }

    /// Add a merge rule. left and right are copied.
    pub fn addRule(
        self: *MergeTable,
        left: []const u8,
        right: []const u8,
        rank: u32,
    ) !void {
        const l = try self.allocator.dupe(u8, left);
        errdefer self.allocator.free(l);
        const r = try self.allocator.dupe(u8, right);
        errdefer self.allocator.free(r);
        // merged = left ++ right
        const m = try std.mem.concat(self.allocator, u8, &.{ left, right });
        errdefer self.allocator.free(m);

        // Build pair key: "left\x00right"
        const key = try std.mem.concat(self.allocator, u8, &.{ left, "\x00", right });
        errdefer self.allocator.free(key);

        try self.rules.append(.{ .left = l, .right = r, .merged = m, .rank = rank });
        try self.pair_rank.put(key, rank);
    }

    /// Return the rank for a (left, right) pair, or null if no rule exists.
    pub fn getRank(
        self: *const MergeTable,
        left: []const u8,
        right: []const u8,
        buf: []u8,
    ) ?u32 {
        // Build lookup key into caller-supplied buffer to avoid allocation.
        if (left.len + 1 + right.len > buf.len) return null;
        @memcpy(buf[0..left.len], left);
        buf[left.len] = 0;
        @memcpy(buf[left.len + 1 .. left.len + 1 + right.len], right);
        const key = buf[0 .. left.len + 1 + right.len];
        return self.pair_rank.get(key);
    }
};

/// Run BPE on a sequence of initial symbol strings.
/// Returns a list of merged token strings (slices into symbols, not owned).
/// Caller supplies output ArrayList([]const u8).
pub fn mergeSymbols(
    symbols: [][]u8,
    table: *const MergeTable,
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]u8),
) !void {
    // Work on a mutable copy of the symbol list.
    var seq = try std.ArrayList([]u8).initCapacity(allocator, symbols.len);
    defer seq.deinit();
    for (symbols) |s| try seq.append(s);

    var key_buf: [512]u8 = undefined;

    while (true) {
        var best_rank: u32 = std.math.maxInt(u32);
        var best_idx: usize = std.math.maxInt(usize);

        // Find the lowest-rank adjacent pair.
        var i: usize = 0;
        while (i + 1 < seq.items.len) : (i += 1) {
            if (table.getRank(seq.items[i], seq.items[i + 1], &key_buf)) |rank| {
                if (rank < best_rank) {
                    best_rank = rank;
                    best_idx  = i;
                }
            }
        }

        if (best_idx == std.math.maxInt(usize)) break; // no more merges

        // Merge best_idx and best_idx+1.
        const merged = try std.mem.concat(
            allocator,
            u8,
            &.{ seq.items[best_idx], seq.items[best_idx + 1] },
        );
        seq.items[best_idx] = merged;
        _ = seq.orderedRemove(best_idx + 1);
    }

    try out.appendSlice(seq.items);
}
