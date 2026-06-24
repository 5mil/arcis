const std = @import("std");

/// Sampling configuration.
pub const SamplerConfig = struct {
    temperature:        f32 = 1.0,
    top_p:              f32 = 0.9,
    top_k:              u32 = 40,
    repetition_penalty: f32 = 1.1,
    repetition_window:  usize = 64,
};

/// Apply temperature scaling in-place to logits.
pub fn applyTemperature(logits: []f32, temp: f32) void {
    if (temp == 1.0) return;
    const inv = 1.0 / temp;
    for (logits) |*l| l.* *= inv;
}

/// Apply repetition penalty: reduce logits for tokens already in context.
pub fn applyRepetitionPenalty(
    logits: []f32,
    context: []const u32,
    penalty: f32,
) void {
    if (penalty == 1.0) return;
    for (context) |id| {
        if (id >= logits.len) continue;
        if (logits[id] > 0) {
            logits[id] /= penalty;
        } else {
            logits[id] *= penalty;
        }
    }
}

/// Softmax over full logits slice in-place.
pub fn softmax(logits: []f32) void {
    var max: f32 = logits[0];
    for (logits[1..]) |v| if (v > max) { max = v; };
    var sum: f32 = 0.0;
    for (logits) |*v| {
        v.* = @exp(v.* - max);
        sum += v.*;
    }
    for (logits) |*v| v.* /= sum;
}

/// Top-k filter: zero out all logits except the top-k highest.
pub fn applyTopK(logits: []f32, k: u32, allocator: std.mem.Allocator) !void {
    if (k == 0 or k >= logits.len) return;
    // Build index array, sort by logit descending, zero below threshold.
    const indices = try allocator.alloc(usize, logits.len);
    defer allocator.free(indices);
    for (indices, 0..) |*idx, i| idx.* = i;
    std.mem.sort(usize, indices, logits, struct {
        pub fn lessThan(ctx: []f32, a: usize, b: usize) bool {
            return ctx[a] > ctx[b];
        }
    }.lessThan);
    for (indices[@intCast(k)..]) |idx| logits[idx] = 0.0;
}

/// Top-p (nucleus) filter: zero out tokens outside the nucleus.
pub fn applyTopP(probs: []f32, p: f32, allocator: std.mem.Allocator) !void {
    if (p >= 1.0) return;
    const indices = try allocator.alloc(usize, probs.len);
    defer allocator.free(indices);
    for (indices, 0..) |*idx, i| idx.* = i;
    std.mem.sort(usize, indices, probs, struct {
        pub fn lessThan(ctx: []f32, a: usize, b: usize) bool {
            return ctx[a] > ctx[b];
        }
    }.lessThan);
    var cumsum: f32 = 0.0;
    for (indices) |idx| {
        cumsum += probs[idx];
        if (cumsum > p) probs[idx] = 0.0;
    }
}

/// Sample a token index from a probability distribution.
pub fn sample(probs: []const f32, rng: *std.Random) u32 {
    const r = rng.float(f32);
    var cumsum: f32 = 0.0;
    for (probs, 0..) |p, i| {
        cumsum += p;
        if (r <= cumsum) return @intCast(i);
    }
    return @intCast(probs.len - 1);
}

/// Argmax: return the index of the highest logit (greedy decoding).
pub fn argmax(logits: []const f32) u32 {
    var best: u32 = 0;
    var best_val = logits[0];
    for (logits[1..], 1..) |v, i| {
        if (v > best_val) { best_val = v; best = @intCast(i); }
    }
    return best;
}

/// Full sampling pipeline: penalty → temperature → top-k → softmax → top-p → sample.
/// Returns the selected token ID.
pub fn nextToken(
    logits: []f32,
    context: []const u32,
    cfg: SamplerConfig,
    rng: *std.Random,
    allocator: std.mem.Allocator,
) !u32 {
    const window_start = if (context.len > cfg.repetition_window)
        context.len - cfg.repetition_window else 0;
    applyRepetitionPenalty(logits, context[window_start..], cfg.repetition_penalty);

    if (cfg.temperature == 0.0) return argmax(logits);

    applyTemperature(logits, cfg.temperature);
    try applyTopK(logits, cfg.top_k, allocator);
    softmax(logits);
    try applyTopP(logits, cfg.top_p, allocator);
    // Re-normalize after top-p zeroing.
    var sum: f32 = 0.0;
    for (logits) |v| sum += v;
    if (sum > 0) for (logits) |*v| v.* /= sum;
    return sample(logits, rng);
}
