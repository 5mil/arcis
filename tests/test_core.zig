//! test_core.zig — integration tests for src/core/
//! Phase 12 — tests/

const std = @import("std");
const tensor = @import("../src/core/tensor.zig");
const dtype  = @import("../src/core/dtype.zig");
const shape  = @import("../src/core/shape.zig");
const config = @import("../src/core/config.zig");

test "Tensor alloc and fill" {
    const allocator = std.testing.allocator;
    var t = try tensor.Tensor.alloc(allocator, &.{ 2, 3 }, .f32);
    defer t.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 6), t.numel());
}

test "Shape rank and numel" {
    const s = shape.Shape.init(&.{ 4, 8, 16 });
    try std.testing.expectEqual(@as(usize, 3), s.rank());
    try std.testing.expectEqual(@as(usize, 512), s.numel());
}

test "DType sizes" {
    try std.testing.expectEqual(@as(usize, 4), dtype.DType.f32.sizeOf());
    try std.testing.expectEqual(@as(usize, 2), dtype.DType.f16.sizeOf());
    try std.testing.expectEqual(@as(usize, 1), dtype.DType.i8.sizeOf());
}

test "Config defaults" {
    const cfg = config.Config.default();
    try std.testing.expectEqual(config.Device.cpu, cfg.device);
    try std.testing.expect(cfg.threads > 0);
}
