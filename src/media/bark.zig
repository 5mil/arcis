//! bark.zig — Bark TTS: three-stage autoregressive generation
//!   text tokens → semantic tokens → coarse acoustic tokens → fine acoustic tokens
//! Phase 5 — src/media/
//! Depends on: bark_tokenizer.zig, src/infer/transformer.zig, sampler.zig
//! Mirrors: src/infer/session.zig (autoregressive loop)

const std = @import("std");
const Allocator = std.mem.Allocator;
const transformer = @import("../infer/transformer.zig");
const sampler_mod = @import("../infer/sampler.zig");
const KVCache = @import("../infer/kvcache.zig").KVCache;

// ---------------------------------------------------------------------------
// Bark config
// ---------------------------------------------------------------------------

pub const BarkConfig = struct {
    // Semantic model
    sem_vocab_size:    usize = 10_000,
    sem_n_layers:      usize = 12,
    sem_n_heads:       usize = 12,
    sem_embed_dim:     usize = 768,
    sem_max_tokens:    usize = 256,
    // Coarse acoustic model
    coarse_vocab_size: usize = 12_096,  // 2 codebooks x 1024 + offsets
    coarse_n_layers:   usize = 12,
    coarse_n_heads:    usize = 12,
    coarse_embed_dim:  usize = 768,
    coarse_max_tokens: usize = 512,
    // Fine acoustic model
    fine_vocab_size:   usize = 1_024,
    fine_n_layers:     usize = 12,
    fine_n_heads:      usize = 12,
    fine_embed_dim:    usize = 768,
    fine_n_codebooks:  usize = 8,
    // Sampling
    temperature:       f32   = 0.7,
    top_k:             usize = 50,
};

// ---------------------------------------------------------------------------
// Bark weights (stub — populated by GGUF loader)
// ---------------------------------------------------------------------------

pub const BarkWeights = struct {
    semantic:  transformer.TransformerWeights,
    coarse:    transformer.TransformerWeights,
    fine:      transformer.TransformerWeights,
};

// ---------------------------------------------------------------------------
// Bark acoustic output
// ---------------------------------------------------------------------------

/// Raw acoustic token array before EnCodec decode.
/// codes[codebook][frame] layout.
pub const AcousticTokens = struct {
    codes:     [][]u32,   // [n_codebooks][n_frames]
    n_codebooks: usize,
    n_frames:  usize,
    allocator: Allocator,

    pub fn deinit(self: *AcousticTokens) void {
        for (self.codes) |cb| self.allocator.free(cb);
        self.allocator.free(self.codes);
    }
};

// ---------------------------------------------------------------------------
// BarkSession
// ---------------------------------------------------------------------------

pub const BarkSession = struct {
    config:    BarkConfig,
    weights:   *BarkWeights,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: BarkConfig, weights: *BarkWeights) BarkSession {
        return .{ .config = config, .weights = weights, .allocator = allocator };
    }

    /// Stage 1: text token IDs → semantic token IDs.
    /// Returns owned slice. Caller frees.
    pub fn textToSemantic(self: *BarkSession, text_tokens: []const u32) ![]u32 {
        const cfg = self.config;
        var out = try std.ArrayList(u32).initCapacity(self.allocator, cfg.sem_max_tokens);
        errdefer out.deinit();
        // TODO: autoregressive transformer loop over semantic model
        // TODO: stop at EOS or sem_max_tokens
        _ = text_tokens;
        return try out.toOwnedSlice();
    }

    /// Stage 2: semantic token IDs → coarse acoustic tokens (2 codebooks).
    /// Returns owned slice [n_frames * 2]. Caller frees.
    pub fn semanticToCoarse(self: *BarkSession, semantic_tokens: []const u32) ![]u32 {
        const cfg = self.config;
        var out = try std.ArrayList(u32).initCapacity(self.allocator, cfg.coarse_max_tokens * 2);
        errdefer out.deinit();
        // TODO: interleaved coarse codebook generation
        // TODO: temperature/top-k sampling via src/infer/sampler.zig
        _ = semantic_tokens;
        return try out.toOwnedSlice();
    }

    /// Stage 3: coarse tokens → fine acoustic tokens (8 codebooks).
    /// Returns AcousticTokens. Caller calls deinit().
    pub fn coarseToFine(self: *BarkSession, coarse_tokens: []const u32) !AcousticTokens {
        const cfg = self.config;
        const n_frames = coarse_tokens.len / 2;
        const codes = try self.allocator.alloc([]u32, cfg.fine_n_codebooks);
        errdefer self.allocator.free(codes);
        for (codes) |*cb| {
            cb.* = try self.allocator.alloc(u32, n_frames);
            @memset(cb.*, 0);
        }
        // TODO: fine model forward pass per codebook
        return AcousticTokens{
            .codes       = codes,
            .n_codebooks = cfg.fine_n_codebooks,
            .n_frames    = n_frames,
            .allocator   = self.allocator,
        };
    }

    /// Full TTS pipeline: text token IDs → AcousticTokens.
    pub fn generate(self: *BarkSession, text_tokens: []const u32) !AcousticTokens {
        const sem  = try self.textToSemantic(text_tokens);
        defer self.allocator.free(sem);
        const coarse = try self.semanticToCoarse(sem);
        defer self.allocator.free(coarse);
        return try self.coarseToFine(coarse);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "BarkConfig defaults" {
    const cfg = BarkConfig{};
    try std.testing.expectEqual(@as(usize, 8), cfg.fine_n_codebooks);
    try std.testing.expectEqual(@as(f32, 0.7), cfg.temperature);
}

test "AcousticTokens deinit" {
    const allocator = std.testing.allocator;
    const n_cb: usize = 2;
    const n_fr: usize = 4;
    const codes = try allocator.alloc([]u32, n_cb);
    for (codes) |*cb| {
        cb.* = try allocator.alloc(u32, n_fr);
        @memset(cb.*, 0);
    }
    var toks = AcousticTokens{
        .codes = codes, .n_codebooks = n_cb, .n_frames = n_fr, .allocator = allocator,
    };
    toks.deinit();
}
