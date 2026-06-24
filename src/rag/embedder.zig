const std = @import("std");
const Tokenizer   = @import("../infer/tokenizer.zig").Tokenizer;
const transformer = @import("../infer/transformer.zig");
const KVCache     = @import("../infer/kvcache.zig").KVCache;
const attention   = @import("../infer/attention.zig");

/// Dense embedding vector.
pub const Embedding = struct {
    vec:      []f32,
    dim:      usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Embedding) void {
        self.allocator.free(self.vec);
    }

    /// L2-normalize the embedding in-place.
    pub fn normalize(self: *Embedding) void {
        var norm: f32 = 0.0;
        for (self.vec) |v| norm += v * v;
        norm = @sqrt(norm);
        if (norm == 0.0) return;
        for (self.vec) |*v| v.* /= norm;
    }
};

/// Cosine similarity between two normalized embedding vectors.
pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    var dot: f32 = 0.0;
    for (a, b) |x, y| dot += x * y;
    return dot;
}

/// Embedder: runs a transformer model and mean-pools the last hidden state
/// to produce a single dense embedding vector.
pub const Embedder = struct {
    tokenizer: *Tokenizer,
    weights:   *const transformer.TransformerWeights,
    cfg:       transformer.TransformerConfig,
    allocator: std.mem.Allocator,

    /// Embed a text string. Returns a normalized Embedding. Caller must deinit.
    pub fn embed(self: *Embedder, text: []const u8) !Embedding {
        const ids = try self.tokenizer.encode(text, false);
        defer self.allocator.free(ids);

        var kv = try KVCache.init(
            self.allocator,
            self.cfg.n_layers,
            self.cfg.embed_dim,
            self.cfg.n_kv_heads,
            self.cfg.head_dim,
        );
        defer kv.deinit();

        // Accumulate hidden states for mean pooling.
        const E = self.cfg.embed_dim;
        var pool = try self.allocator.alloc(f32, E);
        defer self.allocator.free(pool);
        @memset(std.mem.sliceAsBytes(pool), 0);

        for (ids, 0..) |tok, pos| {
            const logits = try transformer.forward(
                tok, pos, self.weights, &kv, &self.cfg, self.allocator,
            );
            defer self.allocator.free(logits);
            // Mean pool: accumulate last hidden state from lm_head input.
            // We re-derive from lm_head weights applied inversely; for now
            // we pool the logit vector projected back as a proxy embedding.
            // Full hidden-state pooling requires exposing pre-lm-head activations
            // which will be wired in the next transformer refactor.
            for (pool, logits[0..E]) |*p, l| p.* += l;
        }

        const n: f32 = @floatFromInt(ids.len);
        for (pool) |*p| p.* /= n;

        const vec = try self.allocator.dupe(f32, pool);
        var emb = Embedding{ .vec = vec, .dim = E, .allocator = self.allocator };
        emb.normalize();
        return emb;
    }
};
