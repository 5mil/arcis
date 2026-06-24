const std = @import("std");
const attention = @import("attention.zig");
const LayerKVCache = @import("kvcache.zig").LayerKVCache;
const KVCache = @import("kvcache.zig").KVCache;

/// Weight matrices for a single transformer layer.
/// All weights are f32 (pre-dequantized). In later stages these will
/// be replaced with quantized views dequantized on-the-fly.
pub const LayerWeights = struct {
    // Attention
    rms_att:  []const f32, // [embed_dim]
    wq:       []const f32, // [n_heads * head_dim x embed_dim]
    wk:       []const f32, // [n_kv_heads * head_dim x embed_dim]
    wv:       []const f32, // [n_kv_heads * head_dim x embed_dim]
    wo:       []const f32, // [embed_dim x n_heads * head_dim]
    // FFN (SwiGLU)
    rms_ffn:  []const f32, // [embed_dim]
    w_gate:   []const f32, // [ffn_dim x embed_dim]
    w_up:     []const f32, // [ffn_dim x embed_dim]
    w_down:   []const f32, // [embed_dim x ffn_dim]
};

/// Full transformer weights.
pub const TransformerWeights = struct {
    layers:       []LayerWeights,
    embed_table:  []const f32, // [vocab_size x embed_dim]
    rms_final:    []const f32, // [embed_dim]
    lm_head:      []const f32, // [vocab_size x embed_dim]
};

/// Configuration for the transformer.
pub const TransformerConfig = struct {
    n_layers:   usize,
    n_heads:    usize,
    n_kv_heads: usize,
    head_dim:   usize,
    embed_dim:  usize,
    ffn_dim:    usize,
    vocab_size: usize,
    rope_theta: f32 = 10_000.0,
};

/// SiLU activation: x * sigmoid(x)
fn silu(x: f32) f32 {
    return x * (1.0 / (1.0 + @exp(-x)));
}

/// SwiGLU feed-forward network: down(silu(gate(x)) * up(x))
/// x is modified in-place (residual added at end).
fn ffnForward(
    x: []f32,
    w: *const LayerWeights,
    cfg: *const TransformerConfig,
    allocator: std.mem.Allocator,
) !void {
    const E = cfg.embed_dim;
    const F = cfg.ffn_dim;

    var xb = try allocator.alloc(f32, E);
    defer allocator.free(xb);
    @memcpy(xb, x);
    attention.rmsNorm(xb, w.rms_ffn, 1e-5);

    var gate_out = try allocator.alloc(f32, F);
    defer allocator.free(gate_out);
    var up_out   = try allocator.alloc(f32, F);
    defer allocator.free(up_out);
    var hidden   = try allocator.alloc(f32, F);
    defer allocator.free(hidden);
    var down_out = try allocator.alloc(f32, E);
    defer allocator.free(down_out);

    attention.matVec(gate_out, w.w_gate, xb, F, E);
    attention.matVec(up_out,   w.w_up,   xb, F, E);

    // SwiGLU: hidden = silu(gate) * up
    for (hidden, gate_out, up_out) |*h, g, u| h.* = silu(g) * u;

    attention.matVec(down_out, w.w_down, hidden, E, F);

    // Residual.
    for (x, down_out) |*xi, d| xi.* += d;
}

/// Forward pass for a single transformer layer.
/// x: embedding vector [embed_dim], modified in-place.
pub fn layerForward(
    x: []f32,
    layer_idx: usize,
    pos: usize,
    weights: *const TransformerWeights,
    kv: *LayerKVCache,
    cfg: *const TransformerConfig,
    allocator: std.mem.Allocator,
) !void {
    const w = &weights.layers[layer_idx];
    const att_cfg = attention.AttentionConfig{
        .n_heads    = cfg.n_heads,
        .n_kv_heads = cfg.n_kv_heads,
        .head_dim   = cfg.head_dim,
        .embed_dim  = cfg.embed_dim,
        .rope_theta = cfg.rope_theta,
    };
    try attention.forward(
        x, w.wq, w.wk, w.wv, w.wo, w.rms_att,
        kv, att_cfg, pos, allocator,
    );
    try ffnForward(x, w, cfg, allocator);
}

/// Full transformer forward pass for a single token at position pos.
/// Returns logits over the vocabulary [vocab_size].
/// Caller owns the returned slice.
pub fn forward(
    token_id: u32,
    pos: usize,
    weights: *const TransformerWeights,
    kvcache: *KVCache,
    cfg: *const TransformerConfig,
    allocator: std.mem.Allocator,
) ![]f32 {
    const E = cfg.embed_dim;

    // Token embedding lookup.
    var x = try allocator.alloc(f32, E);
    errdefer allocator.free(x);
    const emb_base = token_id * E;
    @memcpy(x, weights.embed_table[emb_base .. emb_base + E]);

    // Run all transformer layers.
    for (0..cfg.n_layers) |layer_idx| {
        try layerForward(
            x, layer_idx, pos,
            weights, &kvcache.layers[layer_idx],
            cfg, allocator,
        );
    }

    // Final RMSNorm.
    attention.rmsNorm(x, weights.rms_final, 1e-5);

    // LM head projection → logits.
    var logits = try allocator.alloc(f32, cfg.vocab_size);
    errdefer allocator.free(logits);
    attention.matVec(logits, weights.lm_head, x, cfg.vocab_size, E);

    allocator.free(x);
    return logits;
}
