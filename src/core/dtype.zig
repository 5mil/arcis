/// Supported scalar data types for tensor elements.
pub const DType = enum(u8) {
    f16,
    f32,
    f64,
    bf16,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    bool,

    /// Returns the byte size of a single element for this dtype.
    pub fn byteSize(self: DType) usize {
        return switch (self) {
            .f16 => 2,
            .bf16 => 2,
            .f32 => 4,
            .f64 => 8,
            .i8 => 1,
            .i16 => 2,
            .i32 => 4,
            .i64 => 8,
            .u8 => 1,
            .u16 => 2,
            .u32 => 4,
            .u64 => 8,
            .bool => 1,
        };
    }

    pub fn name(self: DType) []const u8 {
        return switch (self) {
            .f16 => "f16",
            .bf16 => "bf16",
            .f32 => "f32",
            .f64 => "f64",
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "i64",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .bool => "bool",
        };
    }
};
