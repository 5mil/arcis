const std = @import("std");
const gguf = @import("gguf.zig");
const Model = @import("model.zig").Model;
const ModelMeta = @import("model.zig").ModelMeta;

/// Memory-mapped GGUF file (posix only — avoids Zig 0.16 std.Io File migration).
pub const MappedFile = struct {
    data: []align(std.heap.page_size_min) const u8,
    fd: std.posix.fd_t,

    pub fn open(path: []const u8) !MappedFile {
        const fd = try std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
        errdefer std.posix.close(fd);

        const st = try std.posix.fstat(fd);
        const size: usize = @intCast(st.size);
        if (size == 0) return error.EmptyFile;

        const mapped = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        );
        return MappedFile{ .data = mapped, .fd = fd };
    }

    pub fn close(self: *MappedFile) void {
        std.posix.munmap(self.data);
        std.posix.close(self.fd);
        self.* = undefined;
    }

    pub fn tensorBytes(
        self: *const MappedFile,
        offset: u64,
        byte_len: usize,
    ) []const u8 {
        return self.data[offset .. offset + byte_len];
    }
};

fn firstU32(parsed: *const gguf.GGUFFile, keys: []const []const u8) ?u32 {
    for (keys) |k| {
        if (gguf.metaU32(parsed, k)) |v| return v;
    }
    return null;
}

pub fn loadModel(
    allocator: std.mem.Allocator,
    path: []const u8,
) !Model {
    // Map first, then parse header from the mapped bytes (no std.fs.File).
    var mapped = try MappedFile.open(path);
    errdefer mapped.close();

    var parsed = try gguf.parseFromSlice(allocator, mapped.data);
    errdefer parsed.deinit();

    const arch = gguf.metaString(&parsed, "general.architecture") orelse
        return error.MissingArchitecture;

    const n_layers = firstU32(&parsed, &.{ "llama.block_count", "mistral.block_count", "phi.block_count", "qwen2.block_count", "qwen.block_count" }) orelse
        return error.MissingLayerCount;
    const n_ctx = firstU32(&parsed, &.{ "llama.context_length", "mistral.context_length", "qwen2.context_length", "qwen.context_length" }) orelse 0;
    const n_embd = firstU32(&parsed, &.{ "llama.embedding_length", "mistral.embedding_length", "qwen2.embedding_length", "qwen.embedding_length" }) orelse 0;
    const n_heads = firstU32(&parsed, &.{ "llama.attention.head_count", "mistral.attention.head_count", "qwen2.attention.head_count", "qwen.attention.head_count" }) orelse 0;

    const meta = ModelMeta{
        .architecture = arch,
        .n_layers     = n_layers,
        .context_len  = n_ctx,
        .embed_dim    = n_embd,
        .n_heads      = n_heads,
        .tensor_count = @intCast(parsed.tensors.len),
    };

    return Model{
        .gguf      = parsed,
        .mapped    = mapped,
        .meta      = meta,
        .allocator = allocator,
    };
}
