//! test_workflow.zig — integration tests for workflow engine
//! Phase 12 — tests/

const std = @import("std");
const WorkflowSession = @import("../src/workflow/workflow_session.zig").WorkflowSession;
const NodeRegistry    = @import("../src/workflow/node.zig").NodeRegistry;
const NodeIO          = @import("../src/workflow/node.zig").NodeIO;
const Payload         = @import("../src/workflow/node.zig").Payload;
const TriggerKind     = @import("../src/workflow/trigger.zig").TriggerKind;
const JobStatus       = @import("../src/workflow/job.zig").JobStatus;

fn echoNode(io: *NodeIO, _: std.mem.Allocator) anyerror!void {
    if (io.inputs.len > 0) {
        io.outputs[0].payload = io.inputs[0].payload;
    }
}

test "WorkflowSession register and runNow" {
    const allocator = std.testing.allocator;
    var ws = WorkflowSession.init(allocator);
    defer ws.deinit();

    try ws.registry.register("echo", echoNode);

    // Build a single-node graph.
    var graph = @import("../src/workflow/graph.zig").Graph.init(allocator);
    defer graph.deinit();
    const n1 = try graph.addNode("echo");
    _ = n1;

    const wf_id = try ws.registerWorkflow("test-wf", graph);
    const job_id = try ws.runNow(wf_id, .{ .text = "hello" });
    const job = ws.getJob(job_id).?;
    try std.testing.expectEqual(JobStatus.completed, job.status);
}

test "WorkflowSession addTrigger manual" {
    const allocator = std.testing.allocator;
    var ws = WorkflowSession.init(allocator);
    defer ws.deinit();

    var graph = @import("../src/workflow/graph.zig").Graph.init(allocator);
    defer graph.deinit();
    const wf_id = try ws.registerWorkflow("trig-wf", graph);
    try ws.addTrigger(wf_id, .{ .kind = .manual, .workflow_id = wf_id });
    try std.testing.expectEqual(@as(usize, 1), ws.triggers.items.len);
}
