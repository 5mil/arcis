//! graph.zig — directed acyclic workflow graph: nodes, edges, topological sort
//! Phase 6 — src/workflow/
//! Mirrors: src/agents/planner.zig (step graph), src/rag/pipeline.zig (linear chain)

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Node and edge types
// ---------------------------------------------------------------------------

pub const NodeId = u32;

/// The kind of work a node performs.
pub const NodeKind = enum {
    tool,       // invoke a named tool from the tool registry
    llm,        // call an inference session
    transform,  // pure data transformation (no IO)
    condition,  // branch: evaluates a predicate, routes to true/false edge
    merge,      // fan-in: wait for all incoming edges
    input,      // workflow entry point
    output,     // workflow exit point
};

/// A single workflow node.
pub const Node = struct {
    id:       NodeId,
    kind:     NodeKind,
    name:     []const u8,   // human label
    config:   []const u8,   // JSON config blob (tool name, prompt template, etc.)
};

/// A directed edge from src → dst.
pub const Edge = struct {
    src:    NodeId,
    dst:    NodeId,
    label:  ?[]const u8 = null,  // "true"/"false" for condition branches
};

// ---------------------------------------------------------------------------
// Graph
// ---------------------------------------------------------------------------

pub const Graph = struct {
    nodes:     std.ArrayList(Node),
    edges:     std.ArrayList(Edge),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Graph {
        return .{
            .nodes     = std.ArrayList(Node).init(allocator),
            .edges     = std.ArrayList(Edge).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Graph) void {
        self.nodes.deinit();
        self.edges.deinit();
    }

    pub fn addNode(self: *Graph, node: Node) !void {
        try self.nodes.append(node);
    }

    pub fn addEdge(self: *Graph, edge: Edge) !void {
        try self.edges.append(edge);
    }

    /// Return outgoing edges for a node.
    pub fn outEdges(self: Graph, id: NodeId, out: *std.ArrayList(Edge)) !void {
        for (self.edges.items) |e| {
            if (e.src == id) try out.append(e);
        }
    }

    /// Kahn's algorithm topological sort. Returns ordered NodeId slice.
    /// Caller owns returned slice.
    pub fn topoSort(self: Graph, allocator: Allocator) ![]NodeId {
        const n = self.nodes.items.len;
        var in_degree = try allocator.alloc(usize, n);
        defer allocator.free(in_degree);
        @memset(in_degree, 0);

        for (self.edges.items) |e| {
            if (e.dst < n) in_degree[e.dst] += 1;
        }

        var queue = std.ArrayList(NodeId).init(allocator);
        defer queue.deinit();
        for (0..n) |i| {
            if (in_degree[i] == 0) try queue.append(@intCast(i));
        }

        var order = std.ArrayList(NodeId).init(allocator);
        errdefer order.deinit();

        while (queue.items.len > 0) {
            const id = queue.orderedRemove(0);
            try order.append(id);
            for (self.edges.items) |e| {
                if (e.src == id) {
                    in_degree[e.dst] -= 1;
                    if (in_degree[e.dst] == 0) try queue.append(e.dst);
                }
            }
        }

        if (order.items.len != n) return error.CycleDetected;
        return try order.toOwnedSlice();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Graph topo sort linear" {
    const allocator = std.testing.allocator;
    var g = Graph.init(allocator);
    defer g.deinit();
    try g.addNode(.{ .id = 0, .kind = .input,  .name = "in",  .config = "{}" });
    try g.addNode(.{ .id = 1, .kind = .tool,   .name = "t1",  .config = "{}" });
    try g.addNode(.{ .id = 2, .kind = .output, .name = "out", .config = "{}" });
    try g.addEdge(.{ .src = 0, .dst = 1 });
    try g.addEdge(.{ .src = 1, .dst = 2 });
    const order = try g.topoSort(allocator);
    defer allocator.free(order);
    try std.testing.expectEqual(@as(usize, 3), order.len);
    try std.testing.expectEqual(@as(NodeId, 0), order[0]);
    try std.testing.expectEqual(@as(NodeId, 2), order[2]);
}
