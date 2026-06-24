//! viewer.zig — text reading view: retrieve body, paginate, highlight concept mentions
//! Phase 8 — src/library/

const std = @import("std");
const Allocator  = std.mem.Allocator;
const TextRecord = @import("../common/schema.zig").TextRecord;
const Catalog    = @import("catalog.zig").Catalog;
const EntityId   = @import("../common/id.zig").EntityId;

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

pub const Page = struct {
    text_id:    EntityId,
    page_num:   usize,
    total_pages: usize,
    content:    []const u8,  // slice into TextRecord.body — not owned
};

// ---------------------------------------------------------------------------
// Viewer
// ---------------------------------------------------------------------------

pub const Viewer = struct {
    catalog:   *Catalog,
    page_size: usize,   // bytes per page
    allocator: Allocator,

    pub fn init(allocator: Allocator, catalog: *Catalog, page_size: usize) Viewer {
        return .{ .catalog = catalog, .page_size = page_size, .allocator = allocator };
    }

    /// Get a paginated page of a text. Page numbers are 0-indexed.
    pub fn getPage(self: Viewer, text_id: EntityId, page_num: usize) ?Page {
        const rec = self.catalog.texts.getById(text_id) orelse return null;
        const body = rec.body;
        if (body.len == 0) return null;

        const total_pages = (body.len + self.page_size - 1) / self.page_size;
        if (page_num >= total_pages) return null;

        const start = page_num * self.page_size;
        const end   = @min(start + self.page_size, body.len);
        return Page{
            .text_id     = text_id,
            .page_num    = page_num,
            .total_pages = total_pages,
            .content     = body[start..end],
        };
    }

    /// Search for a keyword in a text body. Returns byte offsets of all matches.
    /// Caller owns returned slice.
    pub fn findInText(
        self: Viewer,
        text_id: EntityId,
        keyword: []const u8,
    ) ![]usize {
        const rec = self.catalog.texts.getById(text_id) orelse return &.{};
        var offsets = std.ArrayList(usize).init(self.allocator);
        errdefer offsets.deinit();
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, rec.body, pos, keyword)) |idx| {
            try offsets.append(idx);
            pos = idx + 1;
        }
        return try offsets.toOwnedSlice();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Viewer pagination" {
    const allocator = std.testing.allocator;
    var seq = @import("../common/id.zig").IdSequence.init();
    var cat = @import("catalog.zig").Catalog.init(allocator, &seq);
    defer cat.deinit();

    const id = try cat.ingest("ABCDEFGHIJ", .{ .title = "Test" });
    var viewer = Viewer.init(allocator, &cat, 4);
    const p0 = viewer.getPage(id, 0).?;
    try std.testing.expectEqual(@as(usize, 3), p0.total_pages); // 10 bytes / 4 = 3 pages
    try std.testing.expectEqualStrings("ABCD", p0.content);
    const p2 = viewer.getPage(id, 2).?;
    try std.testing.expectEqualStrings("IJ", p2.content);
}
