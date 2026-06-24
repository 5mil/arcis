//! workflow_session.zig — unified workflow entry point: register, trigger, run, inspect
//! Phase 6 — src/workflow/
//! Mirrors: src/infer/session.zig, src/media/media_session.zig

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph        = @import("graph.zig").Graph;
const NodeRegistry = @import("node.zig").NodeRegistry;
const Payload      = @import("node.zig").Payload;
const TriggerStore = @import("trigger.zig").TriggerStore;
const Trigger      = @import("trigger.zig").Trigger;
const JobStore     = @import("job.zig").JobStore;
const Job          = @import("job.zig").Job;
const Scheduler    = @import("scheduler.zig").Scheduler;
const Runner       = @import("runner.zig").Runner;

// ---------------------------------------------------------------------------
// Workflow definition
// ---------------------------------------------------------------------------

pub const WorkflowId = u32;

pub const Workflow = struct {
    id:    WorkflowId,
    name:  []const u8,
    graph: Graph,
};

// ---------------------------------------------------------------------------
// WorkflowSession
// ---------------------------------------------------------------------------

pub const WorkflowSession = struct {
    workflows:  std.ArrayList(Workflow),
    triggers:   TriggerStore,
    jobs:       JobStore,
    registry:   NodeRegistry,
    scheduler:  Scheduler,
    runner:     Runner,
    next_wf_id: WorkflowId,
    allocator:  Allocator,

    pub fn init(allocator: Allocator) WorkflowSession {
        var triggers = TriggerStore.init(allocator);
        var jobs     = JobStore.init(allocator);
        var registry = NodeRegistry.init(allocator);
        return .{
            .workflows  = std.ArrayList(Workflow).init(allocator),
            .triggers   = triggers,
            .jobs       = jobs,
            .registry   = registry,
            .scheduler  = Scheduler.init(allocator, &triggers, &jobs),
            .runner     = Runner.init(allocator, &registry),
            .next_wf_id = 1,
            .allocator  = allocator,
        };
    }

    pub fn deinit(self: *WorkflowSession) void {
        for (self.workflows.items) |*wf| wf.graph.deinit();
        self.workflows.deinit();
        self.triggers.deinit();
        self.jobs.deinit();
        self.registry.deinit();
        self.scheduler.deinit();
    }

    /// Register a workflow graph. Returns assigned WorkflowId.
    pub fn registerWorkflow(self: *WorkflowSession, name: []const u8, graph: Graph) !WorkflowId {
        const id = self.next_wf_id;
        self.next_wf_id += 1;
        try self.workflows.append(.{ .id = id, .name = name, .graph = graph });
        return id;
    }

    /// Attach a trigger to a registered workflow.
    pub fn addTrigger(self: *WorkflowSession, trigger: Trigger) !void {
        try self.triggers.add(trigger);
    }

    /// Run a workflow immediately with an input payload. Returns job ID.
    pub fn runNow(
        self: *WorkflowSession,
        workflow_id: WorkflowId,
        payload: Payload,
    ) !u64 {
        const wf = for (self.workflows.items) |*w| {
            if (w.id == workflow_id) break w;
        } else return error.WorkflowNotFound;

        const job = try self.jobs.create(workflow_id, null);
        try self.runner.run(&wf.graph, job, payload);
        return job.id;
    }

    /// Advance scheduler by one tick (call from event loop, once per second).
    pub fn tick(self: *WorkflowSession, now_unix_secs: i64) !void {
        try self.scheduler.tick(now_unix_secs);
        const dispatches = self.scheduler.drain();
        for (dispatches) |d| {
            _ = self.runNow(d.trigger.workflow_id, Payload{ .null_val = {} }) catch {};
        }
    }

    /// Fire a named event — triggers all workflows subscribed to it.
    pub fn fireEvent(self: *WorkflowSession, event_name: []const u8) !void {
        const now = @divFloor(std.time.milliTimestamp(), 1000);
        try self.scheduler.fireEvent(event_name, now);
        const dispatches = self.scheduler.drain();
        for (dispatches) |d| {
            _ = self.runNow(d.trigger.workflow_id, Payload{ .null_val = {} }) catch {};
        }
    }

    /// Look up a job by ID.
    pub fn getJob(self: *WorkflowSession, job_id: u64) ?*Job {
        return self.jobs.findById(job_id);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "WorkflowSession init and deinit" {
    const allocator = std.testing.allocator;
    var ws = WorkflowSession.init(allocator);
    defer ws.deinit();
    try std.testing.expectEqual(@as(WorkflowId, 1), ws.next_wf_id);
}
