const std = @import("std");

pub const GPUType = enum {
    nvidia,
    amd,
    apple_silicon,
    intel,
    unknown,
};

pub const HardwareInfo = struct {
    total_ram_mb: u64 = 0,
    gpu_type: GPUType = .unknown,
    gpu_vram_mb: u64 = 0,
    gpu_count: u32 = 0,
    cpu_cores: u32 = 0,
    is_apple_silicon: bool = false,
};

pub fn scan(allocator: std.mem.Allocator) !HardwareInfo {
    var info = HardwareInfo{};
    info.cpu_cores = @as(u32, @intCast(std.Thread.getCpuCount()));
    // Add more detection as needed
    return info;
}