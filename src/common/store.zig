//! store.zig — generic in-memory entity store with ID and URN lookup
//! Phase 7 — src/common/
//! Used by ontology, library, naming, search as their backing store.

const std = @import("std");
const Allocator = std.mem.Allocator;
const EntityId = @import("id.zig").EntityId;

// ---------------------------------------------------------------------------
// Generic EntityStore(T)
// ---------------------------------------------------------------------------

/// A simple growable store for any entity type T that has an `id: EntityId` field.
/// Provides O(1) ID lookup via a hash map and ordered iteration.
pub fn EntityStore(comptime T: type) type {
    return struct {
        const Self = @This();

        items:     std.ArrayList(T),
        id_index:  std.AutoHashMap(EntityId, usize),  // id → items index
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .items     = std.ArrayList(T).init(allocator),
                .id_index  = std.AutoHashMap(EntityId, usize).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit();
            self.id_index.deinit();
        }

        pub fn put(self: *Self, entity: T) !void {
            const idx = self.items.items.len;
            try self.items.append(entity);
            try self.id_index.put(entity.id, idx);
        }

        pub fn getById(self: *Self, id: EntityId) ?*T {
            const idx = self.id_index.get(id) orelse return null;
            return &self.items.items[idx];
        }

        pub fn count(self: Self) usize {
            return self.items.items.len;
        }

        /// Remove by ID. Swaps with last element for O(1) removal; updates index.
        pub fn removeById(self: *Self, id: EntityId) bool {
            const idx = self.id_index.get(id) orelse return false;
            const last_idx = self.items.items.len - 1;
            if (idx != last_idx) {
                const last = self.items.items[last_idx];
                self.items.items[idx] = last;
                self.id_index.put(last.id, idx) catch {};
            }
            _ = self.items.pop();
            _ = self.id_index.remove(id);
            return true;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "EntityStore put and getById" {
    const allocator = std.testing.allocator;
    const schema = @import("schema.zig");

    var store = EntityStore(schema.Annotation).init(allocator);
    defer store.deinit();

    try store.put(.{
        .id = 1, .target_urn = "arcis:concept:00000001",
        .author = "test", .body = "note", .created_at = 0,
    });
    try std.testing.expectEqual(@as(usize, 1), store.count());
    const found = store.getById(1);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("note", found.?.body);
}

test "EntityStore removeById" {
    const allocator = std.testing.allocator;
    const schema = @import("schema.zig");
    var store = EntityStore(schema.Annotation).init(allocator);
    defer store.deinit();
    try store.put(.{ .id = 1, .target_urn = "", .author = "", .body = "", .created_at = 0 });
    try store.put(.{ .id = 2, .target_urn = "", .author = "", .body = "", .created_at = 0 });
    try std.testing.expect(store.removeById(1));
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expect(store.getById(1) == null);
}
