//! bark_tokenizer.zig — Bark text tokenizer: GPT-style BPE → semantic token IDs
//! Phase 5 — src/media/
//! Depends on: src/infer/bpe.zig, vocab.zig
//! Mirrors: src/infer/tokenizer.zig

const std = @import("std");
const Allocator = std.mem.Allocator;
const BPE = @import("../infer/bpe.zig");
const Vocab = @import("../infer/vocab.zig");

// ---------------------------------------------------------------------------
// Bark special tokens
// ---------------------------------------------------------------------------

pub const BARK_PAD_ID:  u32 = 0;
pub const BARK_EOS_ID:  u32 = 1;
pub const BARK_SEM_VOCAB_SIZE: u32 = 10_000; // semantic codebook size

// ---------------------------------------------------------------------------
// BarkTokenizer
// ---------------------------------------------------------------------------

pub const BarkTokenizer = struct {
    bpe:       BPE.BPETokenizer,
    allocator: Allocator,

    pub fn init(allocator: Allocator, bpe: BPE.BPETokenizer) BarkTokenizer {
        return .{ .bpe = bpe, .allocator = allocator };
    }

    pub fn deinit(self: *BarkTokenizer) void {
        self.bpe.deinit();
    }

    /// Encode text → semantic token IDs.
    /// Applies GPT-2 BPE, maps to semantic codebook IDs, appends EOS.
    /// Returns owned slice. Caller frees.
    pub fn encode(self: *BarkTokenizer, text: []const u8) ![]u32 {
        // Reuse BPE encode from src/infer/bpe.zig
        const bpe_ids = try self.bpe.encode(self.allocator, text);
        defer self.allocator.free(bpe_ids);

        var out = try std.ArrayList(u32).initCapacity(self.allocator, bpe_ids.len + 1);
        errdefer out.deinit();

        for (bpe_ids) |id| {
            // Clamp to semantic vocab size; out-of-range tokens map to PAD.
            const sem_id: u32 = if (id < BARK_SEM_VOCAB_SIZE) @intCast(id) else BARK_PAD_ID;
            try out.append(sem_id);
        }
        try out.append(BARK_EOS_ID);
        return try out.toOwnedSlice();
    }

    /// Encode with voice prompt prefix (Bark speaker conditioning).
    /// Prepends prompt token IDs before encoding the text.
    pub fn encodeWithPrompt(
        self: *BarkTokenizer,
        prompt_ids: []const u32,
        text: []const u8,
    ) ![]u32 {
        const text_ids = try self.encode(text);
        defer self.allocator.free(text_ids);

        var out = try std.ArrayList(u32).initCapacity(
            self.allocator, prompt_ids.len + text_ids.len
        );
        errdefer out.deinit();
        try out.appendSlice(prompt_ids);
        try out.appendSlice(text_ids);
        return try out.toOwnedSlice();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "BarkTokenizer constants" {
    try std.testing.expectEqual(@as(u32, 0), BARK_PAD_ID);
    try std.testing.expectEqual(@as(u32, 1), BARK_EOS_ID);
    try std.testing.expectEqual(@as(u32, 10_000), BARK_SEM_VOCAB_SIZE);
}
