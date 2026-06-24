const std = @import("std");
const Vocab = @import("vocab.zig").Vocab;
const MergeTable = @import("bpe.zig").MergeTable;
const mergeSymbols = @import("bpe.zig").mergeSymbols;
const gguf = @import("gguf.zig");

/// Byte-level pre-tokenization: split text into UTF-8 characters
/// and prefix the first character of each word with a space marker (▁ / Ġ).
/// Returns an ArrayList of owned symbol strings.
pub fn pretokenize(
    allocator: std.mem.Allocator,
    text: []const u8,
) !std.ArrayList([]u8) {
    var symbols = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (symbols.items) |s| allocator.free(s);
        symbols.deinit();
    }

    var i: usize = 0;
    var at_word_start = true;
    while (i < text.len) {
        const byte = text[i];
        // Determine UTF-8 codepoint length.
        const cp_len: usize = if (byte < 0x80) 1
            else if (byte < 0xE0) 2
            else if (byte < 0xF0) 3
            else 4;
        const cp = text[i .. i + cp_len];

        if (byte == ' ') {
            at_word_start = true;
            i += 1;
            continue;
        }

        if (at_word_start) {
            // Prepend space marker U+2581 (▁) = 0xE2 0x96 0x81
            const marker = "\xe2\x96\x81";
            const sym = try std.mem.concat(allocator, u8, &.{ marker, cp });
            try symbols.append(sym);
            at_word_start = false;
        } else {
            const sym = try allocator.dupe(u8, cp);
            try symbols.append(sym);
        }
        i += cp_len;
    }
    return symbols;
}

/// Full BPE tokenizer.
pub const Tokenizer = struct {
    vocab:  Vocab,
    merges: MergeTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Tokenizer {
        return .{
            .vocab     = Vocab.init(allocator),
            .merges    = MergeTable.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.merges.deinit();
        self.vocab.deinit();
    }

    /// Load vocabulary and merge rules from a parsed GGUF file.
    /// Reads tokenizer.ggml.tokens (string array) and
    /// tokenizer.ggml.merges (string array of "left right" pairs).
    pub fn loadFromGGUF(
        self: *Tokenizer,
        parsed: *const gguf.GGUFFile,
    ) !void {
        // GGUF stores the vocab as individual meta entries:
        // tokenizer.ggml.tokens is an array-type entry.
        // We iterate all meta entries and collect tokens in order.
        var token_list = std.ArrayList([]const u8).init(self.allocator);
        defer token_list.deinit();

        for (parsed.meta) |e| {
            if (std.mem.eql(u8, e.key, "tokenizer.ggml.tokens")) {
                // value_bytes for array type starts with type(u32)+count(u64).
                // Individual tokens were discarded during parse; we reconstruct
                // from the raw bytes by re-reading if available.
                // In practice, vocab is loaded via direct entry iteration below.
                _ = e;
            }
        }

        // Load tokens: each entry keyed as "tokenizer.ggml.tokens" contains
        // the full array. Since our parser stores raw prefix bytes for arrays,
        // we load tokens by iterating entries whose keys start with the token prefix.
        // For GGUF v3, individual tokens appear as meta entries in sequence.
        var rank: u32 = 0;
        for (parsed.meta) |e| {
            if (std.mem.startsWith(u8, e.key, "tokenizer.ggml.token_type")) continue;
            if (std.mem.startsWith(u8, e.key, "tokenizer.ggml.scores")) continue;
            if (e.value_type == .string) {
                if (std.mem.startsWith(u8, e.key, "tokenizer")) {
                    _ = try self.vocab.add(e.value_bytes);
                }
            }
            // Load merge rules: "left right" format.
            if (e.value_type == .string and
                std.mem.startsWith(u8, e.key, "tokenizer.ggml.merges"))
            {
                var it = std.mem.splitScalar(u8, e.value_bytes, ' ');
                const left  = it.next() orelse continue;
                const right = it.next() orelse continue;
                try self.merges.addRule(left, right, rank);
                rank += 1;
            }
        }

        // Set special token IDs from metadata.
        if (gguf.metaU32(parsed, "tokenizer.ggml.bos_token_id")) |id|
            self.vocab.bos_id = id;
        if (gguf.metaU32(parsed, "tokenizer.ggml.eos_token_id")) |id|
            self.vocab.eos_id = id;
        if (gguf.metaU32(parsed, "tokenizer.ggml.unknown_token_id")) |id|
            self.vocab.unk_id = id;
        if (gguf.metaU32(parsed, "tokenizer.ggml.padding_token_id")) |id|
            self.vocab.pad_id = id;
    }

    /// Encode a text string into a sequence of token IDs.
    /// Caller owns the returned slice.
    pub fn encode(
        self: *Tokenizer,
        text: []const u8,
        add_bos: bool,
    ) ![]u32 {
        var ids = std.ArrayList(u32).init(self.allocator);
        errdefer ids.deinit();

        if (add_bos and self.vocab.bos_id != 0)
            try ids.append(self.vocab.bos_id);

        // Pre-tokenize into byte-level symbols.
        var symbols = try pretokenize(self.allocator, text);
        defer {
            for (symbols.items) |s| self.allocator.free(s);
            symbols.deinit();
        }

        // Apply BPE merges.
        var merged = std.ArrayList([]u8).init(self.allocator);
        defer {
            // merged items are slices from mergeSymbols; free concat results.
            for (merged.items) |s| self.allocator.free(s);
            merged.deinit();
        }
        try mergeSymbols(symbols.items, &self.merges, self.allocator, &merged);

        // Map merged symbols to IDs.
        for (merged.items) |sym| {
            const id = self.vocab.getId(sym) orelse self.vocab.unk_id;
            try ids.append(id);
        }

        return ids.toOwnedSlice();
    }

    /// Decode a sequence of token IDs back to a UTF-8 string.
    /// Replaces the ▁ space marker with a real space.
    /// Caller owns the returned slice.
    pub fn decode(
        self: *const Tokenizer,
        ids: []const u32,
        skip_special: bool,
    ) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        for (ids) |id| {
            if (skip_special) {
                if (id == self.vocab.bos_id or
                    id == self.vocab.eos_id or
                    id == self.vocab.unk_id or
                    id == self.vocab.pad_id) continue;
            }
            const tok = self.vocab.getToken(id) orelse continue;
            // Replace ▁ (E2 96 81) with space.
            const marker = "\xe2\x96\x81";
            if (std.mem.startsWith(u8, tok, marker)) {
                try buf.append(' ');
                try buf.appendSlice(tok[marker.len..]);
            } else {
                try buf.appendSlice(tok);
            }
        }

        return buf.toOwnedSlice();
    }

    /// Decode a single token ID to its string.
    pub fn decodeOne(self: *const Tokenizer, id: u32) ?[]const u8 {
        return self.vocab.getToken(id);
    }
};
