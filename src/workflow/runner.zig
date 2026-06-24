//! runner.zig — graph execution engine: walk topo order, execute nodes, propagate payloads
//! Phase 6 — src/workflow/
//! Mirrors: src/agents/orchestrator.zig (multi-step dispatch)
//!          src/rag/pipeline.zig (linear stage runner)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph     = @import("graph.zig").Graph;
const NodeId    = @import("graph.zig").NodeId;
const NodeRegistry = @import("node.zig").NodeRegistry;
const NodeIO    = @import("node.zig").NodeIO;
const Port      = @import("node.zig").Port;
const Payload   = @import("node.zig").Payload;
const Job       = @import("job.zig").Job;
const JobStatus = @import("job.zig").JobStatus;
const NodeResult = @import("job.zig").NodeResult;

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

pub const Runner = struct {
    registry:  *NodeRegistry,
    allocator: Allocator,

    pub fn init(allocator: Allocator, registry: *NodeRegistry) Runner {
        return .{ .registry = registry, .allocator = allocator };
    }

    /// Execute a workflow graph for a given job.
    /// Walks nodes in topological order, executes each, propagates payloads along edges.
    /// job.status is updated to .completed or .failed on return.
    pub fn run(self: *Runner, graph: *Graph, job: *Job, input_payload: Payload) !void {
        job.status = .running;

        // Topo sort.
        const order = graph.topoSort(self.allocator) catch |err| {
            job.finish(.failed);
            return err;
        };
        defer self.allocator.free(order);

        // State map: NodeId → last output Payload.
        var state = std.AutoHashMap(NodeId, Payload).init(self.allocator);
        defer state.deinit();

        // Seed input node with the job's initial payload.
        if (order.len > 0) try state.put(order[0], input_payload);

        for (order) |node_id| {
            const node = blk: {
                for (graph.nodes.items) |*n| {
                    if (n.id == node_id) break :blk n;
                }
                continue; // node not found — skip
            };

            // Gather input payload from the first incoming edge's source state.
            var in_payload = Payload{ .null_val = {} };
            for (graph.edges.items) |e| {
                if (e.dst == node_id) {
                    if (state.get(e.src)) |p| { in_payload = p; break; }
                }
            }

            // Build NodeIO.
            var in_port  = Port{ .name = "in",  .payload = in_payload };
            var out_port = Port{ .name = "out", .payload = Payload{ .null_val = {} } };
            var io = NodeIO{
                .inputs    = @as([]const Port, @ptrCast((&in_port)[0..1])),
                .outputs   = (&out_port)[0..1],
                .allocator = self.allocator,
            };

            const start_ms = std.time.milliTimestamp();
            var node_status = JobStatus.completed;
            var err_msg: ?[]const u8 = null;

            // Dispatch to registered runner.
            if (self.registry.find(node.name)) |run_fn| {
                run_fn(&io, node.config) catch |err| {
                    node_status = .failed;
                    err_msg = @errorName(err);
                };
            }
            // Unknown node kind — pass through.

            try job.recordNode(.{
                .node_id     = node_id,
                .status      = node_status,
                .output      = null,
                .err_msg     = err_msg,
                .duration_ms = @intCast(std.time.milliTimestamp() - start_ms),
            });

            if (node_status == .failed) {
                job.finish(.failed);
                return;
            }

            // Propagate output payload.
            try state.put(node_id, out_port.payload);
        }

        job.finish(.completed);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Runner completes single-node graph" {
    const allocator = std.testing.allocator;
    var reg = NodeRegistry.init(allocator);
    defer reg.deinit();

    // Register a passthrough node.
    try reg.register(.{ .name = "pass", .run = struct {
        fn run(io: *NodeIO, _: []const u8) anyerror!void {
            io.outputs[0].payload = io.inputs[0].payload;
        }
    }.run });

    var g = Graph.init(allocator);
    defer g.deinit();
    try g.addNode(.{ .id = 0, .kind = .input, .name = "pass", .config = "{}" });

    var js = @import("job.zig").JobStore.init(allocator);
    defer js.deinit();
    const job = try js.create(1, null);

    var runner = Runner.init(allocator, &reg);
    try runner.run(&g, job, Payload{ .text = "hello" });
    try std.testing.expectEqual(JobStatus.completed, job.status);
}
