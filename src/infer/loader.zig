const std = @import("std");
const gguf = @import("gguf.zig");
const Model = @import("model.zig").Model;
const ModelMeta = @import("model.zig").ModelMeta;

/// Memory-mapped view of the GGUF tensor data section.
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

    /// Return a raw byte slice for a tensor given its offset and byte length.
    pub fn tensorBytes(
        self: *const MappedFile,
        offset: u64,
        byte_len: usize,
    ) []const u8 {
        return self.data[offset .. offset + byte_len];
    }
};

/// Load and validate a GGUF model file.
/// Returns a Model with parsed header, index, and open mmap.
/// Caller must call model.deinit().
pub fn loadModel(
    allocator: std.mem.Allocator,
    path: []const u8,
) !Model {
    // Parse header via buffered read.
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var parsed = try gguf.parse(allocator, file);
    errdefer parsed.deinit();

    // Extract required architectural metadata.
    const arch = gguf.metaString(&parsed, "general.architecture") orelse
        return error.MissingArchitecture;

    const n_layers = gguf.metaU32(&parsed, "llama.block_count") orelse
        gguf.metaU32(&parsed, "mistral.block_count") orelse
        gguf.metaU32(&parsed, "phi.block_count") orelse
        return error.MissingLayerCount;

    const n_ctx = gguf.metaU32(&parsed, "llama.context_length") orelse
        gguf.metaU32(&parsed, "mistral.context_length") orelse
        0;

    const n_embd = gguf.metaU32(&parsed, "llama.embedding_length") orelse
        gguf.metaU32(&parsed, "mistral.embedding_length") orelse
        0;

    const n_heads = gguf.metaU32(&parsed, "llama.attention.head_count") orelse
        gguf.metaU32(&parsed, "mistral.attention.head_count") orelse
        0;

    const meta = ModelMeta{
        .architecture = arch,
        .n_layers     = n_layers,
        .context_len  = n_ctx,
        .embed_dim    = n_embd,
        .n_heads      = n_heads,
        .tensor_count = @intCast(parsed.tensors.len),
    };

    // Open mmap for tensor data access.
    const mapped = try MappedFile.open(path);

    return Model{
        .gguf      = parsed,
        .mapped    = mapped,
        .meta      = meta,
        .allocator = allocator,
    };
}
