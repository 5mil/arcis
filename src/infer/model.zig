const std = @import("std");
const gguf = @import("gguf.zig");
const MappedFile = @import("loader.zig").MappedFile;
const dequant = @import("dequant.zig");

pub const ModelMeta = struct {
    architecture: []const u8,
    n_layers:     u32,
    context_len:  u32,
    embed_dim:    u32,
    n_heads:      u32,
    tensor_count: u32,
};

pub const Model = struct {
    gguf:      gguf.GGUFFile,
    mapped:    MappedFile,
    meta:      ModelMeta,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Model) void {
        self.mapped.close();
        self.gguf.deinit();
    }

    pub fn tensorData(self: *const Model, name: []const u8) ?[]const u8 {
        const info = gguf.findTensor(&self.gguf, name) orelse return null;
        var n_elems: usize = 1;
        for (info.dims[0..info.n_dims]) |d| n_elems *= @intCast(d);
        const byte_len = dequant.tensorByteLen(info.ggml_type, n_elems);
        const off = self.gguf.data_section_offset + info.data_offset;
        if (off + byte_len > self.mapped.data.len) return self.mapped.data[off..];
        return self.mapped.tensorBytes(off, byte_len);
    }

    pub fn tensorDims(self: *const Model, name: []const u8) ?[4]u64 {
        const info = gguf.findTensor(&self.gguf, name) orelse return null;
        return info.dims;
    }
};

pub fn tensorByteLen(info: *const gguf.TensorInfo) usize {
    var n: usize = 1;
    for (info.dims[0..info.n_dims]) |d| n *= @intCast(d);
    return dequant.tensorByteLen(info.ggml_type, n);
}
