const std = @import("std");
const DType = @import("dtype.zig").DType;
const Shape = @import("shape.zig").Shape;

/// A multi-dimensional array of typed scalar values.
/// Owns its data buffer; caller must call deinit.
pub const Tensor = struct {
    shape: Shape,
    dtype: DType,
    data: []u8,
    allocator: std.mem.Allocator,

    /// Allocate a zeroed tensor of the given shape and dtype.
    pub fn init(allocator: std.mem.Allocator, shape: Shape, dtype: DType) !Tensor {
        const byte_count = shape.elementCount() * dtype.byteSize();
        const data = try allocator.alloc(u8, byte_count);
        @memset(data, 0);
        return Tensor{
            .shape = shape,
            .dtype = dtype,
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Tensor) void {
        self.allocator.free(self.data);
    }

    /// Total number of elements.
    pub fn numel(self: Tensor) usize {
        return self.shape.elementCount();
    }

    /// Total byte size of the data buffer.
    pub fn byteLen(self: Tensor) usize {
        return self.data.len;
    }

    /// Reinterpret the raw byte buffer as a typed slice.
    /// Caller asserts T matches the tensor's dtype.
    pub fn asSlice(self: Tensor, comptime T: type) []T {
        return std.mem.bytesAsSlice(T, self.data);
    }
};
