const std = @import("std");
const DType = @import("../core/dtype.zig").DType;
const Shape = @import("../core/shape.zig").Shape;

/// GGUF magic bytes: 0x47 0x47 0x55 0x46
pub const GGUF_MAGIC: u32 = 0x46554747;
pub const SUPPORTED_VERSIONS: [2]u32 = .{ 2, 3 };

/// GGUF value types as defined in the spec.
pub const GGUFValueType = enum(u32) {
    uint8   = 0,
    int8    = 1,
    uint16  = 2,
    int16   = 3,
    uint32  = 4,
    int32   = 5,
    float32 = 6,
    bool    = 7,
    string  = 8,
    array   = 9,
    uint64  = 10,
    int64   = 11,
    float64 = 12,
    _,
};

/// GGML tensor types (quantization formats).
pub const GGMLType = enum(u32) {
    f32     = 0,
    f16     = 1,
    q4_0    = 2,
    q4_1    = 3,
    q5_0    = 6,
    q5_1    = 7,
    q8_0    = 8,
    q8_1    = 9,
    q2_k    = 10,
    q3_k    = 11,
    q4_k    = 12,
    q5_k    = 13,
    q6_k    = 14,
    q8_k    = 15,
    bf16    = 30,
    _,
};

/// A key-value metadata entry from the GGUF header.
pub const MetaEntry = struct {
    key: []u8,
    value_type: GGUFValueType,
    /// Raw encoded value bytes; caller interprets per value_type.
    value_bytes: []u8,
};

/// Descriptor for a single tensor stored in the GGUF file.
pub const TensorInfo = struct {
    name: []u8,
    n_dims: u32,
    dims: [4]u64,
    ggml_type: GGMLType,
    /// Byte offset into the tensor data section.
    data_offset: u64,
};

/// Parsed representation of a GGUF file header and tensor index.
/// Does not load tensor data into memory; use mmap or streaming.
pub const GGUFFile = struct {
    version: u32,
    meta: []MetaEntry,
    tensors: []TensorInfo,
    /// Byte offset in the file where tensor data begins.
    data_section_offset: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GGUFFile) void {
        for (self.meta) |*e| {
            self.allocator.free(e.key);
            self.allocator.free(e.value_bytes);
        }
        self.allocator.free(self.meta);
        for (self.tensors) |*t| {
            self.allocator.free(t.name);
        }
        self.allocator.free(self.tensors);
    }
};

/// Read a length-prefixed GGUF string (u64 len + bytes, no null terminator).
fn readString(reader: anytype, allocator: std.mem.Allocator) ![]u8 {
    const len = try reader.readInt(u64, .little);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try reader.readNoEof(buf);
    return buf;
}

/// Read a single metadata value; returns raw bytes for the value.
fn readMetaValue(
    reader: anytype,
    allocator: std.mem.Allocator,
    vtype: GGUFValueType,
) ![]u8 {
    switch (vtype) {
        .uint8, .int8, .bool => {
            const buf = try allocator.alloc(u8, 1);
            try reader.readNoEof(buf);
            return buf;
        },
        .uint16, .int16 => {
            const buf = try allocator.alloc(u8, 2);
            try reader.readNoEof(buf);
            return buf;
        },
        .uint32, .int32, .float32 => {
            const buf = try allocator.alloc(u8, 4);
            try reader.readNoEof(buf);
            return buf;
        },
        .uint64, .int64, .float64 => {
            const buf = try allocator.alloc(u8, 8);
            try reader.readNoEof(buf);
            return buf;
        },
        .string => {
            return readString(reader, allocator);
        },
        .array => {
            // Read array type (u32) + count (u64), then skip element bytes.
            // Store the raw prefix so callers can decode if needed.
            var prefix: [12]u8 = undefined;
            try reader.readNoEof(&prefix);
            const arr_type_raw = std.mem.readInt(u32, prefix[0..4], .little);
            const arr_count = std.mem.readInt(u64, prefix[4..12], .little);
            const arr_type: GGUFValueType = @enumFromInt(arr_type_raw);
            const elem_size: usize = switch (arr_type) {
                .uint8, .int8, .bool => 1,
                .uint16, .int16 => 2,
                .uint32, .int32, .float32 => 4,
                .uint64, .int64, .float64 => 8,
                else => 0,
            };
            if (arr_type == .string) {
                // Variable-length strings: read and discard each one.
                for (0..arr_count) |_| {
                    const s = try readString(reader, allocator);
                    allocator.free(s);
                }
                return allocator.dupe(u8, &prefix);
            } else if (elem_size > 0) {
                const skip = arr_count * elem_size;
                var i: u64 = 0;
                while (i < skip) : (i += 1) _ = try reader.readByte();
                return allocator.dupe(u8, &prefix);
            } else {
                return allocator.dupe(u8, &prefix);
            }
        },
        _ => {
            return error.UnknownGGUFValueType;
        },
    }
}

/// Parse a GGUF file from a seekable stream.
/// Caller owns the returned GGUFFile and must call deinit.
pub fn parse(
    allocator: std.mem.Allocator,
    file: std.fs.File,
) !GGUFFile {
    var br = std.io.bufferedReader(file.reader());
    const reader = br.reader();

    // Magic
    const magic = try reader.readInt(u32, .little);
    if (magic != GGUF_MAGIC) return error.InvalidGGUFMagic;

    // Version
    const version = try reader.readInt(u32, .little);
    var version_ok = false;
    for (SUPPORTED_VERSIONS) |v| { if (v == version) { version_ok = true; break; } }
    if (!version_ok) return error.UnsupportedGGUFVersion;

    // Tensor count + metadata kv count
    const tensor_count = try reader.readInt(u64, .little);
    const meta_count   = try reader.readInt(u64, .little);

    // Metadata
    const meta = try allocator.alloc(MetaEntry, meta_count);
    errdefer allocator.free(meta);
    var meta_init: usize = 0;
    errdefer for (meta[0..meta_init]) |*e| {
        allocator.free(e.key);
        allocator.free(e.value_bytes);
    };
    for (meta[0..meta_count]) |*e| {
        e.key = try readString(reader, allocator);
        const vtype_raw = try reader.readInt(u32, .little);
        e.value_type = @enumFromInt(vtype_raw);
        e.value_bytes = try readMetaValue(reader, allocator, e.value_type);
        meta_init += 1;
    }

    // Tensor index
    const tensors = try allocator.alloc(TensorInfo, tensor_count);
    errdefer allocator.free(tensors);
    var tensors_init: usize = 0;
    errdefer for (tensors[0..tensors_init]) |*t| allocator.free(t.name);
    for (tensors[0..tensor_count]) |*t| {
        t.name   = try readString(reader, allocator);
        t.n_dims = try reader.readInt(u32, .little);
        t.dims   = [_]u64{0} ** 4;
        for (0..t.n_dims) |i| t.dims[i] = try reader.readInt(u64, .little);
        const gt_raw = try reader.readInt(u32, .little);
        t.ggml_type   = @enumFromInt(gt_raw);
        t.data_offset = try reader.readInt(u64, .little);
        tensors_init += 1;
    }

    // Data section starts at current stream position aligned to 32 bytes.
    const pos = try file.getPos();
    const alignment: u64 = 32;
    const data_section_offset = (pos + alignment - 1) & ~(alignment - 1);

    return GGUFFile{
        .version             = version,
        .meta                = meta,
        .tensors             = tensors,
        .data_section_offset = data_section_offset,
        .allocator           = allocator,
    };
}

/// Look up a metadata string value by key.
/// Returns a slice into the MetaEntry's value_bytes.
pub fn metaString(gguf: *const GGUFFile, key: []const u8) ?[]const u8 {
    for (gguf.meta) |e| {
        if (std.mem.eql(u8, e.key, key) and e.value_type == .string) {
            return e.value_bytes;
        }
    }
    return null;
}

/// Look up a u32 metadata value by key.
pub fn metaU32(gguf: *const GGUFFile, key: []const u8) ?u32 {
    for (gguf.meta) |e| {
        if (std.mem.eql(u8, e.key, key) and e.value_type == .uint32) {
            return std.mem.readInt(u32, e.value_bytes[0..4], .little);
        }
    }
    return null;
}

/// Look up a tensor descriptor by name.
pub fn findTensor(gguf: *const GGUFFile, name: []const u8) ?*const TensorInfo {
    for (gguf.tensors) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}
