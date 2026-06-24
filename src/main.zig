const std = @import("std");
const Config = @import("core/config.zig").Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    _ = allocator;

    const cfg = Config.default();
    std.debug.print("Arcis engine v{s} starting...\n", .{cfg.version});
}
