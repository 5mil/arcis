//! name_store.zig — name registry: store, lookup, variant tracking, uniqueness
//! Phase 9 — src/naming/

const std = @import("std");
const Allocator  = std.mem.Allocator;
const EntityId   = @import("../common/id.zig").EntityId;
const IdSequence = @import("../common/id.zig").IdSequence;
const makeUrn    = @import("../common/id.zig").makeUrn;
const URN_BUF_SIZE = @import("../common/id.zig").URN_BUF_SIZE;
const Status     = @import("../common/schema.zig").Status;
const Tradition  = @import("rules.zig").Tradition;
const Rank       = @import("rules.zig").Rank;
const generateName = @import("rules.zig").generateName;

// ---------------------------------------------------------------------------
// NameRecord
// ---------------------------------------------------------------------------

pub const NameKind = enum { space, wizard };

pub const NameRecord = struct {
    id:         EntityId,
    urn:        []const u8,
    value:      []const u8,   // the actual name string
    kind:       NameKind,
    tradition:  Tradition,
    rank:       Rank,
    status:     Status,
    variant_of: ?EntityId,    // points to parent if this is a variant
    created_at: i64,
};

// ---------------------------------------------------------------------------
// NameStore
// ---------------------------------------------------------------------------

pub const NameStore = struct {
    names:      std.ArrayList(NameRecord),
    name_index: std.StringHashMap(EntityId),  // value → id (uniqueness check)
    seq:        *IdSequence,
    allocator:  Allocator,

    pub fn init(allocator: Allocator, seq: *IdSequence) NameStore {
        return .{
            .names      = std.ArrayList(NameRecord).init(allocator),
            .name_index = std.StringHashMap(EntityId).init(allocator),
            .seq        = seq,
            .allocator  = allocator,
        };
    }

    pub fn deinit(self: *NameStore) void {
        self.names.deinit();
        self.name_index.deinit();
    }

    /// Generate and register a new name. Returns EntityId.
    /// If the generated name already exists, retries with seed+1 up to 16 times.
    pub fn generateAndStore(
        self: *NameStore,
        kind: NameKind,
        tradition: Tradition,
        rank: Rank,
        seed: u64,
    ) !EntityId {
        var attempt: u64 = 0;
        while (attempt < 16) : (attempt += 1) {
            const value = try generateName(self.allocator, tradition, rank, seed + attempt);
            if (self.name_index.contains(value)) {
                self.allocator.free(value);
                continue;
            }
            return try self.register(value, kind, tradition, rank, null);
        }
        return error.NameGenerationExhausted;
    }

    /// Register a pre-built name string (takes ownership of value).
    pub fn register(
        self: *NameStore,
        value: []const u8,
        kind: NameKind,
        tradition: Tradition,
        rank: Rank,
        variant_of: ?EntityId,
    ) !EntityId {
        const id  = self.seq.next(.name);
        var urn_buf: [URN_BUF_SIZE]u8 = undefined;
        const urn = try self.allocator.dupe(u8, makeUrn(.name, id, &urn_buf));
        try self.names.append(.{
            .id         = id,
            .urn        = urn,
            .value      = value,
            .kind       = kind,
            .tradition  = tradition,
            .rank       = rank,
            .status     = .validated,
            .variant_of = variant_of,
            .created_at = std.time.milliTimestamp(),
        });
        try self.name_index.put(value, id);
        return id;
    }

    pub fn findByValue(self: *NameStore, value: []const u8) ?EntityId {
        return self.name_index.get(value);
    }

    pub fn count(self: NameStore) usize { return self.names.items.len; }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "NameStore generateAndStore" {
    const allocator = std.testing.allocator;
    var seq  = IdSequence.init();
    var ns   = NameStore.init(allocator, &seq);
    defer ns.deinit();

    const id = try ns.generateAndStore(.wizard, .greek, .sage, 99);
    try std.testing.expect(id > 0);
    try std.testing.expectEqual(@as(usize, 1), ns.count());
    // Stored name is non-empty.
    try std.testing.expect(ns.names.items[0].value.len > 0);
}
