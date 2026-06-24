const std = @import("std");

/// A bidirectional token vocabulary.
/// Maps token strings to IDs and IDs back to token strings.
pub const Vocab = struct {
    /// token string → token ID
    token_to_id: std.StringHashMap(u32),
    /// token ID → token string (owned slices)
    id_to_token: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    /// Special token IDs. 0 = not set.
    bos_id: u32,
    eos_id: u32,
    unk_id: u32,
    pad_id: u32,

    pub fn init(allocator: std.mem.Allocator) Vocab {
        return .{
            .token_to_id = std.StringHashMap(u32).init(allocator),
            .id_to_token = std.ArrayList([]u8).init(allocator),
            .allocator   = allocator,
            .bos_id      = 0,
            .eos_id      = 0,
            .unk_id      = 0,
            .pad_id      = 0,
        };
    }

    pub fn deinit(self: *Vocab) void {
        for (self.id_to_token.items) |s| self.allocator.free(s);
        self.id_to_token.deinit();
        self.token_to_id.deinit();
    }

    /// Add a token and return its assigned ID.
    /// If the token already exists, returns the existing ID.
    pub fn add(self: *Vocab, token: []const u8) !u32 {
        if (self.token_to_id.get(token)) |id| return id;
        const id: u32 = @intCast(self.id_to_token.items.len);
        const owned = try self.allocator.dupe(u8, token);
        errdefer self.allocator.free(owned);
        try self.id_to_token.append(owned);
        try self.token_to_id.put(owned, id);
        return id;
    }

    /// Look up a token string → ID. Returns null if not found.
    pub fn getId(self: *const Vocab, token: []const u8) ?u32 {
        return self.token_to_id.get(token);
    }

    /// Look up an ID → token string. Returns null if out of range.
    pub fn getToken(self: *const Vocab, id: u32) ?[]const u8 {
        if (id >= self.id_to_token.items.len) return null;
        return self.id_to_token.items[id];
    }

    pub fn size(self: *const Vocab) usize {
        return self.id_to_token.items.len;
    }
};
