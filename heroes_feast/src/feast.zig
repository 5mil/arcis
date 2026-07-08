const std = @import("std");
const HardwareScanner = @import("hardware_scanner.zig");

pub const HeroesFeast = struct {
    pub fn init(allocator: std.mem.Allocator) !HeroesFeast {
        const hw = try HardwareScanner.scan(allocator);
        return HeroesFeast{};
    }
};