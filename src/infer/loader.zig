const std = @import("std");
const gguf = @import("gguf.zig");
const Model = @import("model.zig").Model;
const ModelMeta = @import("model.zig").ModelMeta;

/// GGUF file contents held in a heap buffer (Zig 0.16-friendly; no mmap).
pub const MappedFile = struct {
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !MappedFile {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = path_buf[0..path.len :0].ptr;

        const fd: i32 = std.c.open(path_z, .{ .ACCMODE = .RDONLY });
        if (fd < 0) return error.FileNotFound;
        defer _ = std.c.close(fd);

        // Size via lseek (avoids fstat which was removed from std.posix)
        const end = std.c.lseek(fd, 0, std.c.SEEK.END);
        if (end < 0) return error.SeekFailed;
        const size: usize = @intCast(end);
        if (size == 0) return error.EmptyFile;
        if (std.c.lseek(fd, 0, std.c.SEEK.SET) < 0) return error.SeekFailed;

        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);

        var off: usize = 0;
        while (off < size) {
            const n = std.c.read(fd, buf.ptr + off, size - off);
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            off += @intCast(n);
        }
        if (off != size) return error.UnexpectedEOF;

        return MappedFile{ .data = buf, .allocator = allocator };
    }

    pub fn close(self: *MappedFile) void {
        self.allocator.free(self.data);
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
    var mapped = try MappedFile.open(allocator, path);
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
