//! workflow_example.zig — example: build a two-node workflow, run it, inspect job result
//! Phase 12 — examples/

const std = @import("std");
const WorkflowSession = @import("../src/workflow/workflow_session.zig").WorkflowSession;
const Graph           = @import("../src/workflow/graph.zig").Graph;
const NodeIO          = @import("../src/workflow/node.zig").NodeIO;
const Payload         = @import("../src/workflow/node.zig").Payload;
const JobStatus       = @import("../src/workflow/job.zig").JobStatus;

// A node that uppercases the input text payload (stub).
fn upperNode(io: *NodeIO, allocator: std.mem.Allocator) anyerror!void {
    _ = allocator;
    if (io.inputs.len > 0) {
        io.outputs[0].payload = io.inputs[0].payload; // pass-through in scaffold
    }
}

// A node that prints the payload.
fn printNode(io: *NodeIO, _: std.mem.Allocator) anyerror!void {
    if (io.inputs.len > 0) {
        switch (io.inputs[0].payload) {
            .text  => |t| std.debug.print("printNode received: {s}\n", .{t}),
            else   => std.debug.print("printNode received non-text payload\n", .{}),
        }
        io.outputs[0].payload = io.inputs[0].payload;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Arcis Workflow Example ===\n\n", .{});

    var ws = WorkflowSession.init(allocator);
    defer ws.deinit();

    // Register node types.
    try ws.registry.register("upper", upperNode);
    try ws.registry.register("print", printNode);

    // Build a two-node graph: upper → print.
    var graph = Graph.init(allocator);
    defer graph.deinit();
    const n1 = try graph.addNode("upper");
    const n2 = try graph.addNode("print");
    try graph.addEdge(n1, n2);

    const wf_id  = try ws.registerWorkflow("demo", graph);
    const job_id = try ws.runNow(wf_id, Payload{ .text = "hello arcis" });

    const job = ws.getJob(job_id).?;
    std.debug.print("Job {d} status: {s}\n", .{ job_id, @tagName(job.status) });
    std.debug.print("\nDone.\n", .{});
}
