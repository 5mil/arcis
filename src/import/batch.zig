//! batch.zig — bulk import: directory scan, multi-file ingest, progress reporting
//! Phase 7 — src/import/

const std = @import("std");
const Allocator  = std.mem.Allocator;
const Importer   = @import("importer.zig").Importer;
const ImportMeta = @import("importer.zig").ImportMeta;
const ImportFormat = @import("importer.zig").ImportFormat;
const TextRecord = @import("../common/schema.zig").TextRecord;
const EntityStore = @import("../common/store.zig").EntityStore;

// ---------------------------------------------------------------------------
// BatchResult
// ---------------------------------------------------------------------------

pub const BatchResult = struct {
    imported: usize,
    skipped:  usize,
    errors:   usize,
};

// ---------------------------------------------------------------------------
// BatchImporter
// ---------------------------------------------------------------------------

pub const BatchImporter = struct {
    importer:  Importer,
    store:     *EntityStore(TextRecord),
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        importer: Importer,
        store: *EntityStore(TextRecord),
    ) BatchImporter {
        return .{ .importer = importer, .store = store, .allocator = allocator };
    }

    /// Import all eligible files in a directory tree.
    /// Eligible: .txt, .json, .xml files.
    /// meta_default is applied to all files (title/author can be overridden per-file in future).
    pub fn importDir(
        self: *BatchImporter,
        dir_path: []const u8,
        meta_default: ImportMeta,
    ) !BatchResult {
        var result = BatchResult{ .imported = 0, .skipped = 0, .errors = 0 };
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) { result.skipped += 1; continue; }
            const ext_ok =
                std.mem.endsWith(u8, entry.name, ".txt")  or
                std.mem.endsWith(u8, entry.name, ".json") or
                std.mem.endsWith(u8, entry.name, ".xml");
            if (!ext_ok) { result.skipped += 1; continue; }

            // Build full path.
            var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name })
                catch { result.errors += 1; continue; };

            const rec = self.importer.importFile(full_path, meta_default, .auto) catch {
                result.errors += 1;
                continue;
            };
            self.store.put(rec) catch {
                result.errors += 1;
                continue;
            };
            result.imported += 1;
        }
        return result;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "BatchResult zero init" {
    const r = BatchResult{ .imported = 0, .skipped = 0, .errors = 0 };
    try std.testing.expectEqual(@as(usize, 0), r.imported);
}
