const std = @import("std");
const rope = @import("rope.zig");
const LayerKVCache = @import("kvcache.zig").LayerKVCache;

/// Multi-head (grouped-query) attention for a single layer and single token.
/// All weight matrices are pre-dequantized f32 slices.
///
/// n_heads:    number of query heads
/// n_kv_heads: number of key/value heads (n_kv_heads <= n_heads, GQA)
/// head_dim:   dimension per head (embed_dim / n_heads)
/// pos:        current token position
/// rope_theta: RoPE base frequency
pub const AttentionConfig = struct {
    n_heads:    usize,
    n_kv_heads: usize,
    head_dim:   usize,
    embed_dim:  usize,
    rope_theta: f32 = 10_000.0,
};

/// Compute softmax in-place over a slice.
pub fn softmax(x: []f32) void {
    var max: f32 = x[0];
    for (x[1..]) |v| if (v > max) { max = v; };
    var sum: f32 = 0.0;
    for (x) |*v| {
        v.* = @exp(v.* - max);
        sum += v.*;
    }
    for (x) |*v| v.* /= sum;
}

/// Dot product of two equal-length f32 slices.
pub fn dot(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    var s: f32 = 0.0;
    for (a, b) |x, y| s += x * y;
    return s;
}

/// Matrix-vector multiply: out[i] = dot(mat[i*n..(i+1)*n], vec)
/// mat: [m x n] row-major, vec: [n], out: [m]
pub fn matVec(
    out: []f32,
    mat: []const f32,
    vec: []const f32,
    m: usize,
    n: usize,
) void {
    std.debug.assert(out.len >= m);
    std.debug.assert(mat.len >= m * n);
    std.debug.assert(vec.len >= n);
    for (0..m) |i| {
        out[i] = dot(mat[i * n .. (i + 1) * n], vec);
    }
}

/// RMS layer normalization in-place.
/// x: input/output vector, weight: per-dim scale, eps: stability constant.
pub fn rmsNorm(
    x: []f32,
    weight: []const f32,
    eps: f32,
) void {
    std.debug.assert(x.len == weight.len);
    var ss: f32 = 0.0;
    for (x) |v| ss += v * v;
    ss = ss / @as(f32, @floatFromInt(x.len)) + eps;
    const scale = 1.0 / @sqrt(ss);
    for (x, weight) |*v, w| v.* = v.* * scale * w;
}

/// Single-layer multi-head grouped-query attention forward pass.
///
/// x:       input embedding vector [embed_dim] (modified in-place with output)
/// wq:      query weight matrix    [n_heads * head_dim x embed_dim]
/// wk:      key weight matrix      [n_kv_heads * head_dim x embed_dim]
/// wv:      value weight matrix    [n_kv_heads * head_dim x embed_dim]
/// wo:      output projection      [embed_dim x n_heads * head_dim]
/// rms_w:   attention RMSNorm weights [embed_dim]
/// kv:      KV cache for this layer
/// cfg:     attention configuration
/// pos:     current token position
/// scratch: caller-supplied scratch buffer [>= embed_dim + n_heads*head_dim*3]
pub fn forward(
    x: []f32,
    wq: []const f32,
    wk: []const f32,
    wv: []const f32,
    wo: []const f32,
    rms_w: []const f32,
    kv: *LayerKVCache,
    cfg: AttentionConfig,
    pos: usize,
    allocator: std.mem.Allocator,
) !void {
    const E  = cfg.embed_dim;
    const H  = cfg.n_heads;
    const KH = cfg.n_kv_heads;
    const D  = cfg.head_dim;
    const gqa_ratio = H / KH; // heads per kv group

    // Allocate working buffers.
    var xb  = try allocator.alloc(f32, E);
    defer allocator.free(xb);
    var q   = try allocator.alloc(f32, H  * D);
    defer allocator.free(q);
    var k   = try allocator.alloc(f32, KH * D);
    defer allocator.free(k);
    var v   = try allocator.alloc(f32, KH * D);
    defer allocator.free(v);
    var att = try allocator.alloc(f32, pos + 1);
    defer allocator.free(att);
    var xout = try allocator.alloc(f32, E);
    defer allocator.free(xout);

    // RMSNorm on input.
    @memcpy(xb, x);
    rmsNorm(xb, rms_w, 1e-5);

    // Project to Q, K, V.
    matVec(q, wq, xb, H  * D, E);
    matVec(k, wk, xb, KH * D, E);
    matVec(v, wv, xb, KH * D, E);

    // Apply RoPE to each head's Q and K.
    for (0..H) |h| {
        const q_head = q[h * D .. (h + 1) * D];
        const kv_h   = h / gqa_ratio;
        const k_head = k[kv_h * D .. (kv_h + 1) * D];
        rope.applyRoPE(q_head, k_head, D, pos, cfg.rope_theta);
    }

    // Write current K, V into cache.
    kv.write(k, v);

    // Attention: for each query head, attend over all past positions.
    @memset(std.mem.sliceAsBytes(xout), 0);
    const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(D)));

    for (0..H) |h| {
        const q_head = q[h * D .. (h + 1) * D];
        const kv_h   = h / gqa_ratio;

        // Compute attention scores.
        for (0..kv.pos) |t| {
            att[t] = dot(q_head, kv.keyAt(t, kv_h)) * scale;
        }
        softmax(att[0..kv.pos]);

        // Weighted sum of values → output head slice.
        const out_head = xout[h * D .. (h + 1) * D];
        @memset(std.mem.sliceAsBytes(out_head), 0);
        for (0..kv.pos) |t| {
            const val = kv.valueAt(t, kv_h);
            for (out_head, val) |*o, vv| o.* += att[t] * vv;
        }
    }

    // Output projection: xout -> x (residual added).
    var proj = try allocator.alloc(f32, E);
    defer allocator.free(proj);
    matVec(proj, wo, xout, E, H * D);
    for (x, proj) |*xi, p| xi.* += p;
}
