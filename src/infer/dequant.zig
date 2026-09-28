//! Block GGUF → f32. Enough to load R1-Distill Q4_K_M into TransformerWeights.
const std = @import("std");
const GGMLType = @import("gguf.zig").GGMLType;

pub const QK4_0: usize = 32;
pub const QK8_0: usize = 32;
pub const QK_K: usize = 256;

pub fn blockBytes(t: GGMLType) ?usize {
    return switch (t) {
        .f32 => 4,
        .f16, .bf16 => 2,
        .q4_0 => 18,
        .q4_1 => 20,
        .q8_0 => 34,
        .q4_k => 144,
        .q5_k => 176,
        .q6_k => 210,
        .q8_k => 292,
        else => null,
    };
}

pub fn blockElems(t: GGMLType) usize {
    return switch (t) {
        .q4_k, .q5_k, .q6_k, .q8_k => QK_K,
        .q4_0, .q4_1, .q8_0, .q8_1 => 32,
        else => 1,
    };
}

pub fn tensorByteLen(t: GGMLType, n_elems: usize) usize {
    return switch (t) {
        .f32 => n_elems * 4,
        .f16, .bf16 => n_elems * 2,
        else => blk: {
            const be = blockElems(t);
            const bb = blockBytes(t) orelse return n_elems;
            const nb = (n_elems + be - 1) / be;
            break :blk nb * bb;
        },
    };
}

fn f16ToF32(h: u16) f32 {
    const sign: u32 = (@as(u32, h) >> 15) << 31;
    const exp: u32 = (h >> 10) & 0x1F;
    const mant: u32 = h & 0x3FF;
    if (exp == 0) {
        if (mant == 0) return @bitCast(sign);
        const f_mant = @as(f32, @floatFromInt(mant)) / 1024.0;
        const val = f_mant * @as(f32, @exp2(-14.0));
        return if (sign != 0) -val else val;
    } else if (exp == 31) {
        const bits = sign | 0x7F800000 | (mant << 13);
        return @bitCast(bits);
    } else {
        const bits = sign | ((exp + 112) << 23) | (mant << 13);
        return @bitCast(bits);
    }
}

fn readF16(raw: []const u8, off: usize) f32 {
    const bits = std.mem.readInt(u16, raw[off..][0..2], .little);
    return f16ToF32(bits);
}

fn dequantQ40(raw: []const u8, out: []f32) void {
    const nb = out.len / QK4_0;
    var i: usize = 0;
    while (i < nb) : (i += 1) {
        const base = i * 18;
        const d = readF16(raw, base);
        const qs = raw[base + 2 .. base + 18];
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            const b = qs[j];
            out[i * 32 + j] = d * @as(f32, @floatFromInt(@as(i32, b & 0x0F) - 8));
            out[i * 32 + j + 16] = d * @as(f32, @floatFromInt(@as(i32, b >> 4) - 8));
        }
    }
}

fn dequantQ80(raw: []const u8, out: []f32) void {
    const nb = out.len / QK8_0;
    var i: usize = 0;
    while (i < nb) : (i += 1) {
        const base = i * 34;
        const d = readF16(raw, base);
        var j: usize = 0;
        while (j < 32) : (j += 1) {
            const q: i8 = @bitCast(raw[base + 2 + j]);
            out[i * 32 + j] = d * @as(f32, @floatFromInt(q));
        }
    }
}

fn scaleMinK4(j: usize, q: []const u8) struct { d: u8, m: u8 } {
    if (j < 4) {
        return .{ .d = q[j] & 63, .m = q[j + 4] & 63 };
    }
    return .{
        .d = (q[j + 4] & 0x0F) | ((q[j - 4] >> 6) << 4),
        .m = (q[j + 4] >> 4) | ((q[j] >> 6) << 4),
    };
}

fn dequantQ4K(raw: []const u8, out: []f32) void {
    const nb = out.len / QK_K;
    var i: usize = 0;
    while (i < nb) : (i += 1) {
        const base = i * 144;
        const scales = raw[base .. base + 12];
        const qs = raw[base + 12 .. base + 140];
        const d = readF16(raw, base + 140);
        const dmin = readF16(raw, base + 142);
        var dst = i * QK_K;
        var isc: usize = 0;
        var qoff: usize = 0;
        while (isc < 8) : (isc += 1) {
            const sm = scaleMinK4(isc, scales);
            const d1 = d * @as(f32, @floatFromInt(sm.d));
            const m1 = dmin * @as(f32, @floatFromInt(sm.m));
            var j: usize = 0;
            while (j < 32) : (j += 1) {
                const byte = qs[qoff + j / 2];
                const nibble: u8 = if (j % 2 == 0) byte & 0x0F else byte >> 4;
                out[dst + j] = d1 * @as(f32, @floatFromInt(nibble)) - m1;
            }
            dst += 32;
            qoff += 16;
        }
    }
}

pub fn toF32(t: GGMLType, raw: []const u8, out: []f32) !void {
    switch (t) {
        .f32 => {
            if (raw.len < out.len * 4) return error.TensorSizeMismatch;
            const src: []const f32 = @as([*]const f32, @ptrCast(@alignCast(raw.ptr)))[0..out.len];
            @memcpy(out, src);
        },
        .f16 => {
            if (raw.len < out.len * 2) return error.TensorSizeMismatch;
            var i: usize = 0;
            while (i < out.len) : (i += 1) out[i] = readF16(raw, i * 2);
        },
        .q4_0 => dequantQ40(raw, out),
        .q8_0 => dequantQ80(raw, out),
        .q4_k => dequantQ4K(raw, out),
        else => return error.UnsupportedQuantization,
    }
}
