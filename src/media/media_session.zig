//! media_session.zig — unified media dispatch: ASR, TTS, image generation
//! Phase 5 — src/media/
//! Depends on: audio.zig, mel.zig, whisper.zig, bark_tokenizer.zig, bark.zig, encodec.zig, diffusion.zig
//! Mirrors: src/infer/session.zig (unified session entry point)

const std = @import("std");
const Allocator = std.mem.Allocator;

const audio       = @import("audio.zig");
const mel_mod     = @import("mel.zig");
const WhisperSession  = @import("whisper.zig").WhisperSession;
const WhisperConfig   = @import("whisper.zig").WhisperConfig;
const BarkTokenizer   = @import("bark_tokenizer.zig").BarkTokenizer;
const BarkSession     = @import("bark.zig").BarkSession;
const BarkConfig      = @import("bark.zig").BarkConfig;
const EncodecDecoder  = @import("encodec.zig").EncodecDecoder;
const EncodecConfig   = @import("encodec.zig").EncodecConfig;
const DiffusionSession = @import("diffusion.zig").DiffusionSession;
const DiffusionConfig  = @import("diffusion.zig").DiffusionConfig;

// ---------------------------------------------------------------------------
// MediaSession config
// ---------------------------------------------------------------------------

pub const MediaConfig = struct {
    whisper: WhisperConfig   = .{},
    bark:    BarkConfig      = .{},
    encodec: EncodecConfig   = .{},
    diffusion: DiffusionConfig = .{},
    mel:     mel_mod.MelConfig = .{},
};

// ---------------------------------------------------------------------------
// MediaSession
// ---------------------------------------------------------------------------

pub const MediaSession = struct {
    config:    MediaConfig,
    whisper:   *WhisperSession,
    bark_tok:  *BarkTokenizer,
    bark:      *BarkSession,
    encodec:   *EncodecDecoder,
    diffusion: *DiffusionSession,
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        config: MediaConfig,
        whisper: *WhisperSession,
        bark_tok: *BarkTokenizer,
        bark: *BarkSession,
        encodec: *EncodecDecoder,
        diffusion: *DiffusionSession,
    ) MediaSession {
        return .{
            .config    = config,
            .whisper   = whisper,
            .bark_tok  = bark_tok,
            .bark      = bark,
            .encodec   = encodec,
            .diffusion = diffusion,
            .allocator = allocator,
        };
    }

    // -----------------------------------------------------------------------
    // ASR: WAV file path → transcript string
    // -----------------------------------------------------------------------

    /// Transcribe a WAV file. Returns owned UTF-8 string. Caller frees.
    pub fn transcribe(
        self: *MediaSession,
        wav_path: []const u8,
        vocab_data: []const []const u8,
    ) ![]u8 {
        // 1. Load and resample to 16 kHz.
        var buf = try audio.readWavResampled(self.allocator, wav_path);
        defer buf.deinit();

        // 2. Compute log-mel spectrogram.
        var mel_spec = try mel_mod.compute(self.allocator, buf, self.config.mel);
        defer mel_spec.deinit();

        // 3. Whisper encode + decode → transcript.
        return try self.whisper.transcribe(mel_spec, vocab_data, 448);
    }

    // -----------------------------------------------------------------------
    // TTS: text string → WAV AudioBuffer
    // -----------------------------------------------------------------------

    /// Synthesize speech from text. Returns owned AudioBuffer. Caller deinits.
    pub fn synthesize(self: *MediaSession, text: []const u8) !audio.AudioBuffer {
        // 1. Text → semantic token IDs.
        const tokens = try self.bark_tok.encode(text);
        defer self.allocator.free(tokens);

        // 2. Semantic → coarse → fine acoustic tokens.
        var acoustic = try self.bark.generate(tokens);
        defer acoustic.deinit();

        // 3. Acoustic tokens → waveform via EnCodec.
        return try self.encodec.decode(acoustic);
    }

    // -----------------------------------------------------------------------
    // Image generation: text embedding → RGB pixel buffer
    // -----------------------------------------------------------------------

    /// Generate a 512x512 RGB image from a CLIP text embedding.
    /// Returns owned []u8 (size = 512*512*3). Caller frees.
    pub fn generateImage(self: *MediaSession, text_emb: []const f32) ![]u8 {
        return try self.diffusion.generate(text_emb);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "MediaConfig defaults compile" {
    const cfg = MediaConfig{};
    try std.testing.expectEqual(@as(usize, 80), cfg.mel.n_mels);
    try std.testing.expectEqual(@as(usize, 512), cfg.diffusion.img_size);
    try std.testing.expectEqual(@as(u32, 50257), cfg.whisper.sot_id);
}
