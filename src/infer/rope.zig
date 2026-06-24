const std = @import("std");

/// Rotary Position Embedding (RoPE).
/// Applies in-place to query and key vectors for a single head.
/// dim: head dimension (must be even)
/// pos: token position in the sequence
/// theta: base frequency (default 10000.0, LLaMA3 uses 500000.0)
pub fn applyRoPE(
    q: []f32,
    k: []f32,
    dim: usize,
    pos: usize,
    theta: f32,
) void {
    std.debug.assert(dim % 2 == 0);
    std.debug.assert(q.len >= dim);
    std.debug.assert(k.len >= dim);

    var i: usize = 0;
    while (i < dim) : (i += 2) {
        const fi: f32 = @floatFromInt(i);
        const fd: f32 = @floatFromInt(dim);
        const fp: f32 = @floatFromInt(pos);
        const freq = 1.0 / std.math.pow(f32, theta, fi / fd);
        const angle = fp * freq;
        const cos_a = @cos(angle);
        const sin_a = @sin(angle);

        const q0 = q[i];
        const q1 = q[i + 1];
        q[i]     = q0 * cos_a - q1 * sin_a;
        q[i + 1] = q0 * sin_a + q1 * cos_a;

        const k0 = k[i];
        const k1 = k[i + 1];
        k[i]     = k0 * cos_a - k1 * sin_a;
        k[i + 1] = k0 * sin_a + k1 * cos_a;
    }
}

/// Precompute RoPE frequency table for a full context window.
/// Returns a flat array of (cos, sin) pairs for each (pos, dim/2) pair.
/// Shape: [context_len][head_dim/2][2]
/// Caller owns the returned slice.
pub fn precomputeFreqs(
    allocator: std.mem.Allocator,
    head_dim: usize,
    context_len: usize,
    theta: f32,
) ![]f32 {
    const half = head_dim / 2;
    const total = context_len * half * 2;
    const freqs = try allocator.alloc(f32, total);
    for (0..context_len) |pos| {
        for (0..half) |i| {
            const fi: f32 = @floatFromInt(i * 2);
            const fd: f32 = @floatFromInt(head_dim);
            const fp: f32 = @floatFromInt(pos);
            const freq = 1.0 / std.math.pow(f32, theta, fi / fd);
            const angle = fp * freq;
            const base = (pos * half + i) * 2;
            freqs[base]     = @cos(angle);
            freqs[base + 1] = @sin(angle);
        }
    }
    return freqs;
}
