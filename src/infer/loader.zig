const std = @import("std");
const gguf = @import("gguf.zig");
const Model = @import("model.zig").Model;
const ModelMeta = @import("model.zig").ModelMeta;

pub const MappedFile = struct {
    data: []align(std.mem.page_size) const u8,
    handle: std.fs.File,

    pub fn open(path: []const u8) !MappedFile {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();
        const stat = try file.stat();
        const mapped = try std.posix.mmap(
            null,
            stat.size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
        return MappedFile{ .data = mapped, .handle = file };
    }

    pub fn close(self: *MappedFile) void {
        std.posix.munmap(self.data);
        self.handle.close();
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
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var parsed = try gguf.parse(allocator, file);
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

    const mapped = try MappedFile.open(path);
    return Model{
        .gguf      = parsed,
        .mapped    = mapped,
        .meta      = meta,
        .allocator = allocator,
    };
}
