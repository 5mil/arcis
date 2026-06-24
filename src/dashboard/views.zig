//! views.zig — dashboard view descriptors: reading, term, entity, admin, naming
//! Phase 11 — src/dashboard/
//! Each view is a data struct describing what the UI should render.
//! Actual rendering is in zigllm-ui; this module produces the data payloads.

const std = @import("std");
const Allocator  = std.mem.Allocator;
const EntityId   = @import("../common/id.zig").EntityId;
const TextRecord = @import("../common/schema.zig").TextRecord;
const Concept    = @import("../common/schema.zig").Concept;
const Status     = @import("../common/schema.zig").Status;

// ---------------------------------------------------------------------------
// View kinds
// ---------------------------------------------------------------------------

pub const ViewKind = enum {
    reading,    // text body reader
    term,       // ontology term detail
    entity,     // any entity by URN
    search,     // search results
    admin,      // governance + bulk edit
    naming,     // name browser + generator
    workflow,   // workflow graph inspector
};

// ---------------------------------------------------------------------------
// View payloads
// ---------------------------------------------------------------------------

pub const ReadingView = struct {
    text_id:     EntityId,
    title:       []const u8,
    author:      []const u8,
    language:    []const u8,
    page_num:    usize,
    total_pages: usize,
    content:     []const u8,
    tags:        [][]const u8,
};

pub const TermView = struct {
    concept_id:  EntityId,
    label:       []const u8,
    definition:  []const u8,
    domain:      []const u8,
    status:      Status,
    relations:   []RelationSummary,
};

pub const RelationSummary = struct {
    kind:       []const u8,
    target_id:  EntityId,
    target_label: []const u8,
};

pub const SearchView = struct {
    query:   []const u8,
    results: []SearchEntry,
    total:   usize,
};

pub const SearchEntry = struct {
    entity_id: EntityId,
    kind:      []const u8,
    label:     []const u8,
    score:     f32,
    excerpt:   []const u8,
};

pub const AdminView = struct {
    pending_count:    usize,
    validated_count:  usize,
    deprecated_count: usize,
    recent_ids:       []EntityId,
};

pub const NamingView = struct {
    generated_names: []NameEntry,
    total_stored:    usize,
};

pub const NameEntry = struct {
    id:        EntityId,
    value:     []const u8,
    kind:      []const u8,
    tradition: []const u8,
    rank:      []const u8,
};

// ---------------------------------------------------------------------------
// ViewBuilder — assembles view payloads from subsystem data
// ---------------------------------------------------------------------------

pub const ViewBuilder = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) ViewBuilder {
        return .{ .allocator = allocator };
    }

    /// Build a ReadingView from a TextRecord and page info.
    pub fn readingView(
        self: ViewBuilder,
        rec: TextRecord,
        page_num: usize,
        total_pages: usize,
        content: []const u8,
    ) ReadingView {
        _ = self;
        return .{
            .text_id     = rec.id,
            .title       = rec.title,
            .author      = rec.author,
            .language    = rec.language,
            .page_num    = page_num,
            .total_pages = total_pages,
            .content     = content,
            .tags        = rec.thematic_tags,
        };
    }

    /// Build a minimal AdminView from concept store stats.
    pub fn adminView(
        self: ViewBuilder,
        pending: usize,
        validated: usize,
        deprecated: usize,
        recent: []EntityId,
    ) AdminView {
        _ = self;
        return .{
            .pending_count    = pending,
            .validated_count  = validated,
            .deprecated_count = deprecated,
            .recent_ids       = recent,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ViewKind enum count" {
    try std.testing.expectEqual(@as(usize, 7), std.meta.fields(ViewKind).len);
}

test "ViewBuilder readingView" {
    const allocator = std.testing.allocator;
    var vb = ViewBuilder.init(allocator);
    const rec = TextRecord{
        .id = 1, .urn = "", .canonical_urn = "",
        .title = "Iliad", .author = "Homer", .language = "grc",
        .period = "", .source_tradition = "",
        .has_translation = false, .translation_lang = "",
        .thematic_tags = &.{}, .body = "Sing, O goddess",
        .created_at = 0, .updated_at = 0,
    };
    const v = vb.readingView(rec, 0, 1, rec.body);
    try std.testing.expectEqualStrings("Iliad", v.title);
    try std.testing.expectEqual(@as(usize, 0), v.page_num);
}
