const std = @import("std");

/// Per-layer KV cache storing keys and values for all past positions.
/// Supports grouped-query attention (GQA): n_kv_heads <= n_heads.
pub const LayerKVCache = struct {
    /// keys:   [context_len][n_kv_heads][head_dim] as flat f32
    keys:   []f32,
    /// values: [context_len][n_kv_heads][head_dim] as flat f32
    values: []f32,
    n_kv_heads: usize,
    head_dim:   usize,
    context_len: usize,
    /// Number of tokens currently stored.
    pos: usize,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        context_len: usize,
        n_kv_heads: usize,
        head_dim: usize,
    ) !LayerKVCache {
        const size = context_len * n_kv_heads * head_dim;
        const keys   = try allocator.alloc(f32, size);
        const values = try allocator.alloc(f32, size);
        @memset(std.mem.sliceAsBytes(keys),   0);
        @memset(std.mem.sliceAsBytes(values), 0);
        return .{
            .keys        = keys,
            .values      = values,
            .n_kv_heads  = n_kv_heads,
            .head_dim    = head_dim,
            .context_len = context_len,
            .pos         = 0,
            .allocator   = allocator,
        };
    }

    pub fn deinit(self: *LayerKVCache) void {
        self.allocator.free(self.keys);
        self.allocator.free(self.values);
    }

    /// Write key and value vectors for the current position.
    /// k_vec and v_vec must each have length n_kv_heads * head_dim.
    pub fn write(
        self: *LayerKVCache,
        k_vec: []const f32,
        v_vec: []const f32,
    ) void {
        std.debug.assert(self.pos < self.context_len);
        const stride = self.n_kv_heads * self.head_dim;
        const base   = self.pos * stride;
        @memcpy(self.keys[base .. base + stride],   k_vec);
        @memcpy(self.values[base .. base + stride], v_vec);
        self.pos += 1;
    }

    /// Return key slice for a past position and kv head.
    pub fn keyAt(
        self: *const LayerKVCache,
        pos: usize,
        kv_head: usize,
    ) []const f32 {
        const base = (pos * self.n_kv_heads + kv_head) * self.head_dim;
        return self.keys[base .. base + self.head_dim];
    }

    /// Return value slice for a past position and kv head.
    pub fn valueAt(
        self: *const LayerKVCache,
        pos: usize,
        kv_head: usize,
    ) []const f32 {
        const base = (pos * self.n_kv_heads + kv_head) * self.head_dim;
        return self.values[base .. base + self.head_dim];
    }

    pub fn reset(self: *LayerKVCache) void {
        self.pos = 0;
    }
};

/// Full KV cache across all transformer layers.
pub const KVCache = struct {
    layers: []LayerKVCache,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        n_layers: usize,
        context_len: usize,
        n_kv_heads: usize,
        head_dim: usize,
    ) !KVCache {
        const layers = try allocator.alloc(LayerKVCache, n_layers);
        for (layers) |*l| {
            l.* = try LayerKVCache.init(allocator, context_len, n_kv_heads, head_dim);
        }
        return .{ .layers = layers, .allocator = allocator };
    }

    pub fn deinit(self: *KVCache) void {
        for (self.layers) |*l| l.deinit();
        self.allocator.free(self.layers);
    }

    pub fn reset(self: *KVCache) void {
        for (self.layers) |*l| l.reset();
    }
};
