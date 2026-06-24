//! whisper.zig — Whisper ASR: encoder + decoder, GGUF weight loading, greedy decode
//! Phase 5 — src/media/
//! Depends on: mel.zig, src/infer/transformer.zig, attention.zig, gguf.zig, loader.zig
//! Mirrors: src/infer/session.zig, model.zig

const std = @import("std");
const Allocator = std.mem.Allocator;
const MelSpectrogram = @import("mel.zig").MelSpectrogram;
const transformer = @import("../infer/transformer.zig");
const attention = @import("../infer/attention.zig");
const sampler = @import("../infer/sampler.zig");

// ---------------------------------------------------------------------------
// Whisper model config
// ---------------------------------------------------------------------------

pub const WhisperConfig = struct {
    // Encoder
    n_audio_ctx:   usize = 1500,
    n_audio_state: usize = 384,   // tiny: 384, base: 512, small: 768
    n_audio_head:  usize = 6,
    n_audio_layer: usize = 4,
    // Decoder
    n_text_ctx:    usize = 448,
    n_text_state:  usize = 384,
    n_text_head:   usize = 6,
    n_text_layer:  usize = 4,
    // Shared
    n_mels:        usize = 80,
    n_vocab:       usize = 51864,  // multilingual; tiny.en = 51864
    // Special token IDs
    sot_id:        u32   = 50257,  // <|startoftranscript|>
    eot_id:        u32   = 50256,  // <|endoftext|>
    no_speech_id:  u32   = 50361,
    transcribe_id: u32   = 50358,
    lang_en_id:    u32   = 50259,
};

// ---------------------------------------------------------------------------
// Whisper weights (stub — populated by loader)
// ---------------------------------------------------------------------------

pub const WhisperWeights = struct {
    // Encoder
    encoder_layers: []transformer.LayerWeights,
    encoder_pos_emb: []const f32,   // [n_audio_ctx x n_audio_state]
    encoder_conv1_w: []const f32,   // conv1d stem weight
    encoder_conv1_b: []const f32,
    encoder_conv2_w: []const f32,
    encoder_conv2_b: []const f32,
    encoder_ln_w:    []const f32,
    encoder_ln_b:    []const f32,
    // Decoder
    decoder_layers:  []transformer.LayerWeights,
    decoder_pos_emb: []const f32,   // [n_text_ctx x n_text_state]
    decoder_embed:   []const f32,   // [n_vocab x n_text_state]
    decoder_ln_w:    []const f32,
    decoder_ln_b:    []const f32,
};

// ---------------------------------------------------------------------------
// Whisper session
// ---------------------------------------------------------------------------

pub const WhisperSession = struct {
    config:    WhisperConfig,
    weights:   *WhisperWeights,
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        config: WhisperConfig,
        weights: *WhisperWeights,
    ) WhisperSession {
        return .{ .config = config, .weights = weights, .allocator = allocator };
    }

    /// Encode mel spectrogram → encoder hidden states [n_audio_ctx x n_audio_state].
    /// Returns owned slice. Caller frees.
    pub fn encode(self: *WhisperSession, mel: MelSpectrogram) ![]f32 {
        const cfg = self.config;
        const state_size = cfg.n_audio_ctx * cfg.n_audio_state;
        const hidden = try self.allocator.alloc(f32, state_size);
        errdefer self.allocator.free(hidden);
        // TODO: conv1d stem (2x conv stride-2) projecting mel → n_audio_state
        // TODO: add positional embedding
        // TODO: run n_audio_layer transformer encoder layers
        _ = mel;
        @memset(hidden, 0);
        return hidden;
    }

    /// Greedy decode from encoder hidden states → token IDs.
    /// Returns owned slice. Caller frees.
    pub fn decode(self: *WhisperSession, encoder_out: []const f32, max_tokens: usize) ![]u32 {
        const cfg = self.config;
        var tokens = try std.ArrayList(u32).initCapacity(self.allocator, max_tokens);
        errdefer tokens.deinit();

        // Prompt: [sot, lang_en, transcribe]
        try tokens.append(cfg.sot_id);
        try tokens.append(cfg.lang_en_id);
        try tokens.append(cfg.transcribe_id);

        // TODO: cross-attention decoder forward pass with encoder_out
        // TODO: greedy argmax at each step, stop at eot_id
        _ = encoder_out;

        return try tokens.toOwnedSlice();
    }

    /// Full ASR pipeline: mel → transcript string.
    /// Returns owned UTF-8 string. Caller frees.
    pub fn transcribe(
        self: *WhisperSession,
        mel: MelSpectrogram,
        vocab_data: []const []const u8,
        max_tokens: usize,
    ) ![]u8 {
        const enc = try self.encode(mel);
        defer self.allocator.free(enc);
        const tok = try self.decode(enc, max_tokens);
        defer self.allocator.free(tok);

        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        for (tok) |id| {
            if (id < vocab_data.len) {
                try out.appendSlice(vocab_data[id]);
            }
        }
        return try out.toOwnedSlice();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "WhisperConfig defaults" {
    const cfg = WhisperConfig{};
    try std.testing.expectEqual(@as(usize, 384), cfg.n_audio_state);
    try std.testing.expectEqual(@as(u32, 50257), cfg.sot_id);
}
