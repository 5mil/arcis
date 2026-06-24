const std = @import("std");
const gguf = @import("gguf.zig");
const MappedFile = @import("loader.zig").MappedFile;

/// High-level architectural metadata extracted from GGUF.
pub const ModelMeta = struct {
    architecture: []const u8,
    n_layers:     u32,
    context_len:  u32,
    embed_dim:    u32,
    n_heads:      u32,
    tensor_count: u32,
};

/// A loaded model: parsed GGUF header + memory-mapped tensor data.
pub const Model = struct {
    gguf:      gguf.GGUFFile,
    mapped:    MappedFile,
    meta:      ModelMeta,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Model) void {
        self.mapped.close();
        self.gguf.deinit();
    }

    /// Return the raw byte slice for a named tensor.
    pub fn tensorData(self: *const Model, name: []const u8) ?[]const u8 {
        const info = gguf.findTensor(&self.gguf, name) orelse return null;
        const byte_len = tensorByteLen(info);
        return self.mapped.tensorBytes(
            self.gguf.data_section_offset + info.data_offset,
            byte_len,
        );
    }

    /// Return the shape of a named tensor as a [4]u64 dims array.
    pub fn tensorDims(self: *const Model, name: []const u8) ?[4]u64 {
        const info = gguf.findTensor(&self.gguf, name) orelse return null;
        return info.dims;
    }
};

/// Compute byte length for a tensor from its TensorInfo.
pub fn tensorByteLen(info: *const gguf.TensorInfo) usize {
    var n: u64 = 1;
    for (info.dims[0..info.n_dims]) |d| n *= d;
    const bytes_per_elem: u64 = switch (info.ggml_type) {
        .f32  => 4,
        .f16, .bf16 => 2,
        .q8_0 => 1, // approximate; block-quantized types vary
        .q4_0, .q4_1 => 1,
        .q5_0, .q5_1 => 1,
        .q2_k, .q3_k, .q4_k, .q5_k, .q6_k, .q8_k => 1,
        _ => 1,
    };
    return @intCast(n * bytes_per_elem);
}
