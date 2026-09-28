//! Load GGUF tensors into f32 TransformerWeights (F32/F16/Q4_0/Q8_0/Q4_K).
const std = @import("std");
const Model = @import("model.zig").Model;
const gguf = @import("gguf.zig");
const dequant = @import("dequant.zig");
const transformer = @import("transformer.zig");
const LayerWeights = transformer.LayerWeights;
const TransformerWeights = transformer.TransformerWeights;
const TransformerConfig = transformer.TransformerConfig;

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
    dequant.toF32(info.ggml_type, raw, out) catch |e| {
        std.log.err("quant {s} on {s}: {}", .{ @tagName(info.ggml_type), name, e });
        return e;
    };
    return out;
}

fn firstU32(model: *const Model, keys: []const []const u8) ?u32 {
    for (keys) |k| {
        if (gguf.metaU32(&model.gguf, k)) |v| return v;
    }
    return null;
}

pub fn configFromModel(model: *const Model) !TransformerConfig {
    const meta = model.meta;
    const n_kv = firstU32(model, &.{ "llama.attention.head_count_kv", "mistral.attention.head_count_kv", "qwen2.attention.head_count_kv" }) orelse meta.n_heads;
    const ffn = firstU32(model, &.{ "llama.feed_forward_length", "mistral.feed_forward_length", "qwen2.feed_forward_length" }) orelse meta.embed_dim * 4;
    const vocab = firstU32(model, &.{ "llama.vocab_size", "qwen2.vocab_size" }) orelse 32000;
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

pub fn loadWeights(
    allocator: std.mem.Allocator,
    model: *const Model,
) !TransformerWeights {
    const cfg = try configFromModel(model);
    const n = cfg.n_layers;
    var layers = try allocator.alloc(LayerWeights, n);
    errdefer allocator.free(layers);
    var allocated = std.ArrayList([]f32).init(allocator);
    defer allocated.deinit();

    const embed = try tensorToF32(allocator, model, "token_embd.weight");
    try allocated.append(embed);
    const rms_final = try tensorToF32(allocator, model, "output_norm.weight");
    try allocated.append(rms_final);
    const lm_head = tensorToF32(allocator, model, "output.weight") catch embed;
    if (lm_head.ptr != embed.ptr) try allocated.append(lm_head);

    for (0..n) |i| {
        var buf: [64]u8 = undefined;
        const rms_att = try tensorToF32(allocator, model, try std.fmt.bufPrint(&buf, "blk.{d}.attn_norm.weight", .{i}));
        try allocated.append(rms_att);
        const wq = try tensorToF32(allocator, model, try std.fmt.bufPrint(&buf, "blk.{d}.attn_q.weight", .{i}));
        try allocated.append(wq);
        const wk = try tensorToF32(allocator, model, try std.fmt.bufPrint(&buf, "blk.{d}.attn_k.weight", .{i}));
        try allocated.append(wk);
        const wv = try tensorToF32(allocator, model, try std.fmt.bufPrint(&buf, "blk.{d}.attn_v.weight", .{i}));
        try allocated.append(wv);
        const wo = try tensorToF32(allocator, model, try std.fmt.bufPrint(&buf, "blk.{d}.attn_output.weight", .{i}));
        try allocated.append(wo);
        const rms_ffn = try tensorToF32(allocator, model, try std.fmt.bufPrint(&buf, "blk.{d}.ffn_norm.weight", .{i}));
        try allocated.append(rms_ffn);
        const w_gate = try tensorToF32(allocator, model, try std.fmt.bufPrint(&buf, "blk.{d}.ffn_gate.weight", .{i}));
        try allocated.append(w_gate);
        const w_up = try tensorToF32(allocator, model, try std.fmt.bufPrint(&buf, "blk.{d}.ffn_up.weight", .{i}));
        try allocated.append(w_up);
        const w_down = try tensorToF32(allocator, model, try std.fmt.bufPrint(&buf, "blk.{d}.ffn_down.weight", .{i}));
        try allocated.append(w_down);
        layers[i] = .{ .rms_att = rms_att, .wq = wq, .wk = wk, .wv = wv, .wo = wo, .rms_ffn = rms_ffn, .w_gate = w_gate, .w_up = w_up, .w_down = w_down };
    }
    return TransformerWeights{ .layers = layers, .embed_table = embed, .rms_final = rms_final, .lm_head = lm_head };
}

pub fn freeWeights(allocator: std.mem.Allocator, w: *TransformerWeights) void {
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
