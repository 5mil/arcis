//! encodec.zig — EnCodec neural audio codec: acoustic tokens → f32 waveform
//! Phase 5 — src/media/
//! Depends on: bark.zig (AcousticTokens), src/core/tensor.zig
//! Mirrors: src/infer/kvcache.zig (flat buffer management)

const std = @import("std");
const Allocator = std.mem.Allocator;
const AcousticTokens = @import("bark.zig").AcousticTokens;
const AudioBuffer = @import("audio.zig").AudioBuffer;

// ---------------------------------------------------------------------------
// EnCodec config
// ---------------------------------------------------------------------------

pub const EncodecConfig = struct {
    n_codebooks:   usize = 8,
    codebook_size: usize = 1_024,
    frame_rate:    u32   = 75,        // tokens per second
    sample_rate:   u32   = 24_000,    // output sample rate
    hop_samples:   usize = 320,       // samples per frame (24000/75)
    embed_dim:     usize = 128,       // per-codebook embedding dim
    n_residual:    usize = 4,         // residual quantizer depth used
};

// ---------------------------------------------------------------------------
// EnCodec weights (stub)
// ---------------------------------------------------------------------------

pub const EncodecWeights = struct {
    codebooks:   [][]f32,   // [n_codebooks][codebook_size * embed_dim]
    decoder_w:   []const f32,
    decoder_b:   []const f32,
};

// ---------------------------------------------------------------------------
// EncodecDecoder
// ---------------------------------------------------------------------------

pub const EncodecDecoder = struct {
    config:    EncodecConfig,
    weights:   *EncodecWeights,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: EncodecConfig, weights: *EncodecWeights) EncodecDecoder {
        return .{ .config = config, .weights = weights, .allocator = allocator };
    }

    /// Look up and sum residual embeddings for all codebooks at a single frame.
    /// out: [embed_dim * n_codebooks] summed embedding.
    fn embedFrame(self: *EncodecDecoder, frame_codes: []const u32, out: []f32) void {
        @memset(out, 0);
        const D = self.config.embed_dim;
        for (frame_codes, 0..) |code, cb| {
            if (cb >= self.config.n_codebooks) break;
            const base = code * D;
            const emb = self.weights.codebooks[cb];
            for (0..D) |d| {
                out[cb * D + d] += emb[base + d];
            }
        }
    }

    /// Decode AcousticTokens → mono f32 AudioBuffer at config.sample_rate.
    /// Returns owned AudioBuffer. Caller must call deinit().
    pub fn decode(self: *EncodecDecoder, tokens: AcousticTokens) !AudioBuffer {
        const cfg = self.config;
        const n_frames = tokens.n_frames;
        const n_samples = n_frames * cfg.hop_samples;

        const waveform = try self.allocator.alloc(f32, n_samples);
        errdefer self.allocator.free(waveform);
        @memset(waveform, 0);

        const embed_total = cfg.embed_dim * cfg.n_codebooks;
        const frame_emb = try self.allocator.alloc(f32, embed_total);
        defer self.allocator.free(frame_emb);

        // Per-frame: embed → decoder → fill hop_samples
        var frame_codes = try self.allocator.alloc(u32, cfg.n_codebooks);
        defer self.allocator.free(frame_codes);

        for (0..n_frames) |f| {
            for (0..cfg.n_codebooks) |cb| {
                frame_codes[cb] = if (cb < tokens.n_codebooks) tokens.codes[cb][f] else 0;
            }
            self.embedFrame(frame_codes, frame_emb);
            // TODO: ConvTranspose1d decoder upsampling (hop_samples output per frame)
            // Placeholder: fill silence
            const base = f * cfg.hop_samples;
            @memset(waveform[base .. base + cfg.hop_samples], 0);
        }

        return AudioBuffer{
            .samples     = waveform,
            .sample_rate = cfg.sample_rate,
            .allocator   = self.allocator,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "EncodecConfig defaults" {
    const cfg = EncodecConfig{};
    try std.testing.expectEqual(@as(u32, 24_000), cfg.sample_rate);
    try std.testing.expectEqual(@as(usize, 320), cfg.hop_samples);
}
