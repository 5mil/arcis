//! scheduler.zig — tick-based cron scheduler: fires due triggers, enqueues jobs
//! Phase 6 — src/workflow/
//! Mirrors: src/agents/orchestrator.zig dispatch loop

const std = @import("std");
const Allocator = std.mem.Allocator;
const TriggerStore = @import("trigger.zig").TriggerStore;
const TriggerKind  = @import("trigger.zig").TriggerKind;
const Trigger      = @import("trigger.zig").Trigger;
const JobStore     = @import("job.zig").JobStore;

// ---------------------------------------------------------------------------
// PendingDispatch — trigger fires waiting to be executed
// ---------------------------------------------------------------------------

pub const PendingDispatch = struct {
    trigger:     Trigger,
    fired_at:    i64,
};

// ---------------------------------------------------------------------------
// Scheduler
// ---------------------------------------------------------------------------

pub const Scheduler = struct {
    triggers:  *TriggerStore,
    jobs:      *JobStore,
    queue:     std.ArrayList(PendingDispatch),
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        triggers: *TriggerStore,
        jobs: *JobStore,
    ) Scheduler {
        return .{
            .triggers  = triggers,
            .jobs      = jobs,
            .queue     = std.ArrayList(PendingDispatch).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.queue.deinit();
    }

    /// Call once per second. Checks all cron triggers against now_unix_secs.
    /// Enqueues any that fire into self.queue.
    pub fn tick(self: *Scheduler, now_unix_secs: i64) !void {
        for (self.triggers.triggers.items) |t| {
            if (!t.enabled) continue;
            if (t.kind != .schedule) continue;
            const spec = t.cron orelse continue;
            if (TriggerStore.cronFires(spec, now_unix_secs)) {
                try self.queue.append(.{ .trigger = t, .fired_at = now_unix_secs });
            }
        }
    }

    /// Fire a named event: enqueue all matching event triggers.
    pub fn fireEvent(self: *Scheduler, event_name: []const u8, now_unix_secs: i64) !void {
        var matches = std.ArrayList(Trigger).init(self.allocator);
        defer matches.deinit();
        try self.triggers.findByEvent(event_name, &matches);
        for (matches.items) |t| {
            try self.queue.append(.{ .trigger = t, .fired_at = now_unix_secs });
        }
    }

    /// Fire a webhook trigger by path.
    pub fn fireWebhook(self: *Scheduler, path: []const u8, now_unix_secs: i64) !void {
        for (self.triggers.triggers.items) |t| {
            if (!t.enabled or t.kind != .webhook) continue;
            if (t.webhook_path) |wp| {
                if (std.mem.eql(u8, wp, path)) {
                    try self.queue.append(.{ .trigger = t, .fired_at = now_unix_secs });
                }
            }
        }
    }

    /// Drain all pending dispatches — called by the runner each cycle.
    pub fn drain(self: *Scheduler) []PendingDispatch {
        const items = self.queue.items;
        self.queue.clearRetainingCapacity();
        return items;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Scheduler tick enqueues matching cron" {
    const allocator = std.testing.allocator;
    var ts = TriggerStore.init(allocator);
    defer ts.deinit();
    var js = JobStore.init(allocator);
    defer js.deinit();
    var sched = Scheduler.init(allocator, &ts, &js);
    defer sched.deinit();

    // Trigger fires every minute at second 0.
    try ts.add(.{ .id = 1, .kind = .schedule, .workflow_id = 1,
        .cron = .{ .second = 0, .minute = 255, .hour = 255 } });

    try sched.tick(0);    // second=0 — should fire
    try std.testing.expectEqual(@as(usize, 1), sched.queue.items.len);
    try sched.tick(1);    // second=1 — should not fire
    try std.testing.expectEqual(@as(usize, 1), sched.queue.items.len);
}
