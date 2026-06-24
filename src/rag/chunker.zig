const std = @import("std");

/// A single text chunk with source metadata.
pub const Chunk = struct {
    text:       []u8,
    source_id:  []u8,
    chunk_idx:  usize,
    char_start: usize,
    char_end:   usize,
    allocator:  std.mem.Allocator,

    pub fn deinit(self: *Chunk) void {
        self.allocator.free(self.text);
        self.allocator.free(self.source_id);
    }
};

/// Chunking strategy.
pub const ChunkStrategy = enum {
    fixed_size,
    sentence,
    paragraph,
};

/// Chunker configuration.
pub const ChunkerConfig = struct {
    strategy:   ChunkStrategy = .fixed_size,
    chunk_size: usize = 512,
    overlap:    usize = 64,
};

/// Split text into overlapping fixed-size character chunks.
fn chunkFixed(
    allocator: std.mem.Allocator,
    text: []const u8,
    source_id: []const u8,
    cfg: ChunkerConfig,
    out: *std.ArrayList(Chunk),
) !void {
    var start: usize = 0;
    var idx: usize = 0;
    while (start < text.len) {
        const end = @min(start + cfg.chunk_size, text.len);
        const slice = try allocator.dupe(u8, text[start..end]);
        const sid   = try allocator.dupe(u8, source_id);
        try out.append(.{
            .text       = slice,
            .source_id  = sid,
            .chunk_idx  = idx,
            .char_start = start,
            .char_end   = end,
            .allocator  = allocator,
        });
        if (end == text.len) break;
        start += cfg.chunk_size - cfg.overlap;
        idx   += 1;
    }
}

/// Split text at paragraph boundaries (double newline).
fn chunkParagraph(
    allocator: std.mem.Allocator,
    text: []const u8,
    source_id: []const u8,
    out: *std.ArrayList(Chunk),
) !void {
    var it = std.mem.splitSequence(u8, text, "\n\n");
    var idx: usize = 0;
    var pos: usize = 0;
    while (it.next()) |para| {
        const trimmed = std.mem.trim(u8, para, " \t\n\r");
        if (trimmed.len == 0) { pos += para.len + 2; continue; }
        const slice = try allocator.dupe(u8, trimmed);
        const sid   = try allocator.dupe(u8, source_id);
        try out.append(.{
            .text       = slice,
            .source_id  = sid,
            .chunk_idx  = idx,
            .char_start = pos,
            .char_end   = pos + para.len,
            .allocator  = allocator,
        });
        pos += para.len + 2;
        idx += 1;
    }
}

/// Main chunking entry point. Caller owns all returned Chunk items.
pub fn chunk(
    allocator: std.mem.Allocator,
    text: []const u8,
    source_id: []const u8,
    cfg: ChunkerConfig,
) !std.ArrayList(Chunk) {
    var out = std.ArrayList(Chunk).init(allocator);
    errdefer {
        for (out.items) |*c| c.deinit();
        out.deinit();
    }
    switch (cfg.strategy) {
        .fixed_size => try chunkFixed(allocator, text, source_id, cfg, &out),
        .paragraph  => try chunkParagraph(allocator, text, source_id, &out),
        .sentence   => try chunkFixed(allocator, text, source_id, cfg, &out), // sentence splitter added in next pass
    }
    return out;
}
