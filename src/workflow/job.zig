//! job.zig — workflow job: a single workflow execution instance with status tracking
//! Phase 6 — src/workflow/
//! Mirrors: src/agents/orchestrator.zig (task dispatch + result tracking)

const std = @import("std");
const Allocator = std.mem.Allocator;
const NodeId = @import("graph.zig").NodeId;

// ---------------------------------------------------------------------------
// Job status
// ---------------------------------------------------------------------------

pub const JobStatus = enum {
    pending,
    running,
    completed,
    failed,
    cancelled,
};

// ---------------------------------------------------------------------------
// Node execution result
// ---------------------------------------------------------------------------

pub const NodeResult = struct {
    node_id:  NodeId,
    status:   JobStatus,
    output:   ?[]const u8 = null,  // JSON-serialised output payload
    err_msg:  ?[]const u8 = null,
    duration_ms: u64 = 0,
};

// ---------------------------------------------------------------------------
// Job
// ---------------------------------------------------------------------------

pub const Job = struct {
    id:           u64,
    workflow_id:  u32,
    trigger_id:   ?u32,
    status:       JobStatus,
    started_at:   i64,   // Unix ms
    finished_at:  i64,
    node_results: std.ArrayList(NodeResult),
    allocator:    Allocator,

    pub fn init(allocator: Allocator, id: u64, workflow_id: u32, trigger_id: ?u32) Job {
        return .{
            .id           = id,
            .workflow_id  = workflow_id,
            .trigger_id   = trigger_id,
            .status       = .pending,
            .started_at   = std.time.milliTimestamp(),
            .finished_at  = 0,
            .node_results = std.ArrayList(NodeResult).init(allocator),
            .allocator    = allocator,
        };
    }

    pub fn deinit(self: *Job) void {
        self.node_results.deinit();
    }

    pub fn recordNode(self: *Job, result: NodeResult) !void {
        try self.node_results.append(result);
    }

    pub fn finish(self: *Job, status: JobStatus) void {
        self.status      = status;
        self.finished_at = std.time.milliTimestamp();
    }

    pub fn durationMs(self: Job) i64 {
        return self.finished_at - self.started_at;
    }
};

// ---------------------------------------------------------------------------
// JobStore — in-memory job log
// ---------------------------------------------------------------------------

pub const JobStore = struct {
    jobs:      std.ArrayList(Job),
    next_id:   u64,
    allocator: Allocator,

    pub fn init(allocator: Allocator) JobStore {
        return .{ .jobs = std.ArrayList(Job).init(allocator), .next_id = 1, .allocator = allocator };
    }

    pub fn deinit(self: *JobStore) void {
        for (self.jobs.items) |*j| j.deinit();
        self.jobs.deinit();
    }

    pub fn create(self: *JobStore, workflow_id: u32, trigger_id: ?u32) !*Job {
        const id = self.next_id;
        self.next_id += 1;
        try self.jobs.append(Job.init(self.allocator, id, workflow_id, trigger_id));
        return &self.jobs.items[self.jobs.items.len - 1];
    }

    pub fn findById(self: *JobStore, id: u64) ?*Job {
        for (self.jobs.items) |*j| {
            if (j.id == id) return j;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Job lifecycle" {
    const allocator = std.testing.allocator;
    var store = JobStore.init(allocator);
    defer store.deinit();
    const job = try store.create(1, null);
    try std.testing.expectEqual(JobStatus.pending, job.status);
    job.finish(.completed);
    try std.testing.expectEqual(JobStatus.completed, job.status);
    try std.testing.expect(job.durationMs() >= 0);
}
