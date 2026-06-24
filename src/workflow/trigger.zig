//! trigger.zig — workflow triggers: manual, scheduled (cron), event, webhook
//! Phase 6 — src/workflow/
//! Mirrors: n8n trigger model; complements scheduler.zig

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Trigger kinds
// ---------------------------------------------------------------------------

pub const TriggerKind = enum {
    manual,     // user-initiated via API or dashboard
    schedule,   // cron-style time trigger
    event,      // internal engine event (e.g. "new_document_ingested")
    webhook,    // inbound HTTP POST
};

/// Cron-style schedule: second/minute/hour/day/month/weekday.
/// Use 255 as wildcard ("*").
pub const CronSpec = struct {
    second:  u8  = 0,
    minute:  u8  = 0,
    hour:    u8  = 0,
    day:     u8  = 255,  // wildcard
    month:   u8  = 255,
    weekday: u8  = 255,
};

/// A trigger definition attached to a workflow.
pub const Trigger = struct {
    id:         u32,
    kind:       TriggerKind,
    workflow_id: u32,
    cron:       ?CronSpec   = null,   // only for .schedule
    event_name: ?[]const u8 = null,   // only for .event
    webhook_path: ?[]const u8 = null, // only for .webhook
    enabled:    bool = true,
};

// ---------------------------------------------------------------------------
// TriggerStore
// ---------------------------------------------------------------------------

pub const TriggerStore = struct {
    triggers:  std.ArrayList(Trigger),
    allocator: Allocator,

    pub fn init(allocator: Allocator) TriggerStore {
        return .{ .triggers = std.ArrayList(Trigger).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *TriggerStore) void {
        self.triggers.deinit();
    }

    pub fn add(self: *TriggerStore, t: Trigger) !void {
        try self.triggers.append(t);
    }

    /// Find all enabled triggers of a given kind.
    pub fn findByKind(self: TriggerStore, kind: TriggerKind, out: *std.ArrayList(Trigger)) !void {
        for (self.triggers.items) |t| {
            if (t.kind == kind and t.enabled) try out.append(t);
        }
    }

    /// Find all enabled triggers for a named event.
    pub fn findByEvent(self: TriggerStore, event_name: []const u8, out: *std.ArrayList(Trigger)) !void {
        for (self.triggers.items) |t| {
            if (t.kind == .event and t.enabled) {
                if (t.event_name) |en| {
                    if (std.mem.eql(u8, en, event_name)) try out.append(t);
                }
            }
        }
    }

    /// Check if a cron trigger fires at a given timestamp (Unix seconds).
    pub fn cronFires(spec: CronSpec, ts: i64) bool {
        const s = @as(u8, @intCast(@mod(ts, 60)));
        const m = @as(u8, @intCast(@mod(@divFloor(ts, 60), 60)));
        const h = @as(u8, @intCast(@mod(@divFloor(ts, 3600), 24)));
        const matches = struct {
            fn f(field: u8, val: u8) bool { return field == 255 or field == val; }
        }.f;
        return matches(spec.second, s) and matches(spec.minute, m) and matches(spec.hour, h);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "CronSpec wildcard fires every second" {
    const spec = CronSpec{}; // second=0, all wildcards
    try std.testing.expect(TriggerStore.cronFires(spec, 0));
    try std.testing.expect(TriggerStore.cronFires(spec, 3600));
}

test "TriggerStore findByEvent" {
    const allocator = std.testing.allocator;
    var store = TriggerStore.init(allocator);
    defer store.deinit();
    try store.add(.{ .id = 1, .kind = .event, .workflow_id = 10, .event_name = "doc_ingested" });
    var out = std.ArrayList(Trigger).init(allocator);
    defer out.deinit();
    try store.findByEvent("doc_ingested", &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
}
