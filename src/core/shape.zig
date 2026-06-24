const std = @import("std");

/// Maximum supported tensor rank.
pub const MAX_RANK: usize = 8;

/// Describes the dimensionality of a tensor.
pub const Shape = struct {
    dims: [MAX_RANK]usize,
    rank: usize,

    pub fn init(dims: []const usize) Shape {
        var s = Shape{ .dims = [_]usize{0} ** MAX_RANK, .rank = dims.len };
        for (dims, 0..) |d, i| s.dims[i] = d;
        return s;
    }

    /// Total number of elements across all dimensions.
    pub fn elementCount(self: Shape) usize {
        if (self.rank == 0) return 0;
        var count: usize = 1;
        for (self.dims[0..self.rank]) |d| count *= d;
        return count;
    }

    /// Returns true if both shapes are identical in rank and all dims.
    pub fn eql(self: Shape, other: Shape) bool {
        if (self.rank != other.rank) return false;
        for (self.dims[0..self.rank], other.dims[0..other.rank]) |a, b| {
            if (a != b) return false;
        }
        return true;
    }

    pub fn format(
        self: Shape,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll("[");
        for (self.dims[0..self.rank], 0..) |d, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{d}", .{d});
        }
        try writer.writeAll("]");
    }
};
