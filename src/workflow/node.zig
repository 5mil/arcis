//! node.zig — node execution context: input/output data payload, node runner interface
//! Phase 6 — src/workflow/
//! Mirrors: src/agents/tool.zig (dispatch interface)

const std = @import("std");
const Allocator = std.mem.Allocator;
const NodeId = @import("graph.zig").NodeId;

// ---------------------------------------------------------------------------
// Data payload passed between nodes
// ---------------------------------------------------------------------------

/// Tagged union of values that flow across edges.
pub const Payload = union(enum) {
    text:   []const u8,
    bytes:  []const u8,
    number: f64,
    flag:   bool,
    null_val: void,
};

/// Named payload slot (a node may have multiple inputs/outputs).
pub const Port = struct {
    name:    []const u8,
    payload: Payload,
};

/// Input/output bundle for a node execution.
pub const NodeIO = struct {
    inputs:  []const Port,
    outputs: []Port,     // caller pre-allocates, runner fills
    allocator: Allocator,
};

// ---------------------------------------------------------------------------
// NodeRunner interface
// ---------------------------------------------------------------------------

/// Function signature every node type must implement.
pub const NodeRunFn = *const fn (io: *NodeIO, config: []const u8) anyerror!void;

/// Registry entry: maps a NodeKind string label to a runner function.
pub const NodeRunner = struct {
    name: []const u8,
    run:  NodeRunFn,
};

/// Global node runner registry.
pub const NodeRegistry = struct {
    runners:   std.ArrayList(NodeRunner),
    allocator: Allocator,

    pub fn init(allocator: Allocator) NodeRegistry {
        return .{ .runners = std.ArrayList(NodeRunner).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *NodeRegistry) void {
        self.runners.deinit();
    }

    pub fn register(self: *NodeRegistry, runner: NodeRunner) !void {
        try self.runners.append(runner);
    }

    pub fn find(self: NodeRegistry, name: []const u8) ?NodeRunFn {
        for (self.runners.items) |r| {
            if (std.mem.eql(u8, r.name, name)) return r.run;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Payload variants" {
    const p = Payload{ .number = 3.14 };
    try std.testing.expectEqual(@as(f64, 3.14), p.number);
}

test "NodeRegistry register and find" {
    const allocator = std.testing.allocator;
    var reg = NodeRegistry.init(allocator);
    defer reg.deinit();
    const runner = NodeRunner{ .name = "echo", .run = struct {
        fn run(io: *NodeIO, _: []const u8) anyerror!void {
            io.outputs[0].payload = io.inputs[0].payload;
        }
    }.run };
    try reg.register(runner);
    try std.testing.expect(reg.find("echo") != null);
    try std.testing.expect(reg.find("missing") == null);
}
