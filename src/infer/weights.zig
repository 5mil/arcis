//! weights.zig — Load GGUF tensors into the f32 TransformerWeights layout
//!
//! Current support: F16 and F32 tensors only.
//! Quantized formats (Q4_K, Q5_K, Q8_0, …) will be added later via on-the-fly dequant.
//!
//! Expected tensor names follow the llama.cpp / GGUF conventions for Llama-style models:
//!   token_embd.weight
//!   output_norm.weight
//!   output.weight          (or tied to token_embd)
//!   blk.{i}.attn_norm.weight
//!   blk.{i}.attn_q.weight
//!   blk.{i}.attn_k.weight
//!   blk.{i}.attn_v.weight
//!   blk.{i}.attn_output.weight
//!   blk.{i}.ffn_norm.weight
//!   blk.{i}.ffn_gate.weight
//!   blk.{i}.ffn_up.weight
//!   blk.{i}.ffn_down.weight

const std = @import("std");
const Model = @import("model.zig").Model;
const gguf = @import("gguf.zig");
const transformer = @import("transformer.zig");
const LayerWeights = transformer.LayerWeights;
const TransformerWeights = transformer.TransformerWeights;
const TransformerConfig = transformer.TransformerConfig;

/// Convert a raw GGUF tensor byte slice into an owned f32 slice.
/// Supports F32 (copy) and F16 (convert). Returns error for quantized types.
fn tensorToF32(
    allocator: std.mem.Allocator,
    model: *const Model,
    name: []const u8,
) ![]f32 {
    const info = gguf.findTensor(&model.gguf, name) orelse {
        std.log.err("missing tensor: {s}", .{name});
        return error.MissingTensor;
    };

    const raw = model.tensorData(name) orelse return error.MissingTensorData;

    var n_elems: usize = 1;
    for (info.dims[0..info.n_dims]) |d| n_elems *= @intCast(d);

    const out = try allocator.alloc(f32, n_elems);
    errdefer allocator.free(out);

    switch (info.ggml_type) {
        .f32 => {
            if (raw.len < n_elems * 4) return error.TensorSizeMismatch;
            const src: []const f32 = @as([*]const f32, @ptrCast(@alignCast(raw.ptr)))[0..n_elems];
            @memcpy(out, src);
        },
        .f16 => {
            if (raw.len < n_elems * 2) return error.TensorSizeMismatch;
            const src: []const u16 = @as([*]const u16, @ptrCast(@alignCast(raw.ptr)))[0..n_elems];
            for (out, src) |*o, h| {
                o.* = f16ToF32(h);
            }
        },
        else => {
            std.log.err("unsupported quant type {s} for tensor {s} — only F16/F32 supported right now",
                .{ @tagName(info.ggml_type), name });
            return error.UnsupportedQuantization;
        },
    }
    return out;
}

/// IEEE-754 half → float conversion (software).
fn f16ToF32(h: u16) f32 {
    const sign: u32 = (@as(u32, h) >> 15) << 31;
    const exp:  u32 = (h >> 10) & 0x1F;
    const mant: u32 = h & 0x3FF;

    if (exp == 0) {
        if (mant == 0) return @bitCast(sign); // ±0
        // Subnormal
        const f_mant = @as(f32, @floatFromInt(mant)) / 1024.0;
        const val = f_mant * @as(f32, @exp2(-14.0));
        return if (sign != 0) -val else val;
    } else if (exp == 31) {
        // Inf / NaN
        const bits = sign | 0x7F800000 | (mant << 13);
        return @bitCast(bits);
    } else {
        const bits = sign | ((exp + 112) << 23) | (mant << 13);
        return @bitCast(bits);
    }
}

/// Build TransformerConfig from ModelMeta + extra GGUF keys.
pub fn configFromModel(model: *const Model) !TransformerConfig {
    const meta = model.meta;
    const n_kv = gguf.metaU32(&model.gguf, "llama.attention.head_count_kv") orelse
        gguf.metaU32(&model.gguf, "mistral.attention.head_count_kv") orelse
        meta.n_heads;

    const ffn = gguf.metaU32(&model.gguf, "llama.feed_forward_length") orelse
        gguf.metaU32(&model.gguf, "mistral.feed_forward_length") orelse
        meta.embed_dim * 4; // fallback

    const vocab = gguf.metaU32(&model.gguf, "llama.vocab_size") orelse
        gguf.metaU32(&model.gguf, "tokenizer.ggml.tokens") orelse // may not work
        32000; // common default

    const head_dim = if (meta.n_heads > 0) meta.embed_dim / meta.n_heads else 64;

    return TransformerConfig{
        .n_layers   = meta.n_layers,
        .n_heads    = meta.n_heads,
        .n_kv_heads = n_kv,
        .head_dim   = head_dim,
        .embed_dim  = meta.embed_dim,
        .ffn_dim    = ffn,
        .vocab_size = vocab,
        .rope_theta = 10_000.0,
    };
}

/// Load all required tensors and build an owned TransformerWeights.
/// Caller must free with `freeWeights`.
pub fn loadWeights(
    allocator: std.mem.Allocator,
    model: *const Model,
) !TransformerWeights {
    const cfg = try configFromModel(model);
    const n = cfg.n_layers;

    var layers = try allocator.alloc(LayerWeights, n);
    errdefer allocator.free(layers);

    // Track everything we allocate so we can free on error
    var allocated = std.ArrayList([]f32).init(allocator);
    defer allocated.deinit();

    const embed = try tensorToF32(allocator, model, "token_embd.weight");
    try allocated.append(embed);

    const rms_final = try tensorToF32(allocator, model, "output_norm.weight");
    try allocated.append(rms_final);

    // LM head may be tied to embedding
    const lm_head = tensorToF32(allocator, model, "output.weight") catch embed;
    if (lm_head.ptr != embed.ptr) try allocated.append(lm_head);

    for (0..n) |i| {
        var buf: [64]u8 = undefined;

        const rms_att = try tensorToF32(allocator, model,
            try std.fmt.bufPrint(&buf, "blk.{d}.attn_norm.weight", .{i}));
        try allocated.append(rms_att);

        const wq = try tensorToF32(allocator, model,
            try std.fmt.bufPrint(&buf, "blk.{d}.attn_q.weight", .{i}));
        try allocated.append(wq);

        const wk = try tensorToF32(allocator, model,
            try std.fmt.bufPrint(&buf, "blk.{d}.attn_k.weight", .{i}));
        try allocated.append(wk);

        const wv = try tensorToF32(allocator, model,
            try std.fmt.bufPrint(&buf, "blk.{d}.attn_v.weight", .{i}));
        try allocated.append(wv);

        const wo = try tensorToF32(allocator, model,
            try std.fmt.bufPrint(&buf, "blk.{d}.attn_output.weight", .{i}));
        try allocated.append(wo);

        const rms_ffn = try tensorToF32(allocator, model,
            try std.fmt.bufPrint(&buf, "blk.{d}.ffn_norm.weight", .{i}));
        try allocated.append(rms_ffn);

        const w_gate = try tensorToF32(allocator, model,
            try std.fmt.bufPrint(&buf, "blk.{d}.ffn_gate.weight", .{i}));
        try allocated.append(w_gate);

        const w_up = try tensorToF32(allocator, model,
            try std.fmt.bufPrint(&buf, "blk.{d}.ffn_up.weight", .{i}));
        try allocated.append(w_up);

        const w_down = try tensorToF32(allocator, model,
            try std.fmt.bufPrint(&buf, "blk.{d}.ffn_down.weight", .{i}));
        try allocated.append(w_down);

        layers[i] = .{
            .rms_att = rms_att,
            .wq      = wq,
            .wk      = wk,
            .wv      = wv,
            .wo      = wo,
            .rms_ffn = rms_ffn,
            .w_gate  = w_gate,
            .w_up    = w_up,
            .w_down  = w_down,
        };
    }

    // Ownership transferred to caller — do not free allocated list items here.
    // The caller will free via freeWeights.
    return TransformerWeights{
        .layers      = layers,
        .embed_table = embed,
        .rms_final   = rms_final,
        .lm_head     = lm_head,
    };
}

/// Free all memory owned by a TransformerWeights produced by loadWeights.
pub fn freeWeights(allocator: std.mem.Allocator, w: *TransformerWeights) void {
    // Free unique tensors (lm_head may be tied to embed_table)
    const tied = w.lm_head.ptr == w.embed_table.ptr;

    allocator.free(w.embed_table);
    allocator.free(w.rms_final);
    if (!tied) allocator.free(w.lm_head);

    for (w.layers) |layer| {
        allocator.free(layer.rms_att);
        allocator.free(layer.wq);
        allocator.free(layer.wk);
        allocator.free(layer.wv);
        allocator.free(layer.wo);
        allocator.free(layer.rms_ffn);
        allocator.free(layer.w_gate);
        allocator.free(layer.w_up);
        allocator.free(layer.w_down);
    }
    allocator.free(w.layers);
}
