//! audio.zig — raw PCM I/O, WAV reader/writer, normalization, resampling
//! Phase 5 — src/media/
//! Mirrors: src/core/dtype.zig, src/infer/loader.zig

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const TARGET_SAMPLE_RATE: u32 = 16_000;
pub const MAX_CHANNELS: u8 = 8;

// ---------------------------------------------------------------------------
// PCM buffer
// ---------------------------------------------------------------------------

/// Owned mono f32 PCM buffer at a known sample rate.
pub const AudioBuffer = struct {
    samples: []f32,
    sample_rate: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, n_samples: usize, sample_rate: u32) !AudioBuffer {
        const samples = try allocator.alloc(f32, n_samples);
        return AudioBuffer{ .samples = samples, .sample_rate = sample_rate, .allocator = allocator };
    }

    pub fn deinit(self: *AudioBuffer) void {
        self.allocator.free(self.samples);
    }

    pub fn duration_secs(self: AudioBuffer) f32 {
        return @as(f32, @floatFromInt(self.samples.len)) / @as(f32, @floatFromInt(self.sample_rate));
    }
};

// ---------------------------------------------------------------------------
// WAV header
// ---------------------------------------------------------------------------

/// Minimal PCM WAV header (44 bytes, little-endian).
const WavHeader = packed struct {
    riff: [4]u8,           // "RIFF"
    chunk_size: u32,
    wave: [4]u8,           // "WAVE"
    fmt: [4]u8,            // "fmt "
    subchunk1_size: u32,   // 16 for PCM
    audio_format: u16,     // 1 = PCM
    num_channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
    data: [4]u8,           // "data"
    subchunk2_size: u32,
};

// ---------------------------------------------------------------------------
// WAV reader
// ---------------------------------------------------------------------------

/// Read a WAV file, downmix to mono, normalize i16 → f32 in [-1, 1].
/// Returns an owned AudioBuffer at the file's native sample rate.
/// Caller must call AudioBuffer.deinit().
pub fn readWav(allocator: Allocator, path: []const u8) !AudioBuffer {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const reader = file.reader();

    var header: WavHeader = undefined;
    const header_bytes = std.mem.asBytes(&header);
    const n_read = try reader.readAll(header_bytes);
    if (n_read < @sizeOf(WavHeader)) return error.InvalidWavHeader;

    if (!std.mem.eql(u8, &header.riff, "RIFF")) return error.NotRiff;
    if (!std.mem.eql(u8, &header.wave, "WAVE")) return error.NotWave;
    if (header.audio_format != 1) return error.UnsupportedFormat; // PCM only
    if (header.bits_per_sample != 16) return error.UnsupportedBitDepth;
    if (header.num_channels == 0 or header.num_channels > MAX_CHANNELS) return error.UnsupportedChannelCount;

    const n_frames = header.subchunk2_size / (header.num_channels * 2);
    const buf = try allocator.alloc(i16, n_frames * header.num_channels);
    defer allocator.free(buf);

    const raw = std.mem.sliceAsBytes(buf);
    _ = try reader.readAll(raw);

    // Downmix to mono f32
    const out = try allocator.alloc(f32, n_frames);
    const ch: f32 = @floatFromInt(header.num_channels);
    for (0..n_frames) |i| {
        var sum: f32 = 0.0;
        for (0..header.num_channels) |c| {
            sum += @as(f32, @floatFromInt(buf[i * header.num_channels + c]));
        }
        out[i] = (sum / ch) / 32768.0;
    }

    return AudioBuffer{ .samples = out, .sample_rate = header.sample_rate, .allocator = allocator };
}

// ---------------------------------------------------------------------------
// WAV writer
// ---------------------------------------------------------------------------

/// Write a mono f32 AudioBuffer to a PCM WAV file (16-bit, mono).
pub fn writeWav(buf: AudioBuffer, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    const writer = file.writer();

    const n_samples: u32 = @intCast(buf.samples.len);
    const data_size: u32 = n_samples * 2;

    const header = WavHeader{
        .riff = "RIFF".*,
        .chunk_size = 36 + data_size,
        .wave = "WAVE".*,
        .fmt = "fmt ".*,
        .subchunk1_size = 16,
        .audio_format = 1,
        .num_channels = 1,
        .sample_rate = buf.sample_rate,
        .byte_rate = buf.sample_rate * 2,
        .block_align = 2,
        .bits_per_sample = 16,
        .data = "data".*,
        .subchunk2_size = data_size,
    };

    try writer.writeAll(std.mem.asBytes(&header));

    for (buf.samples) |s| {
        const clamped = std.math.clamp(s, -1.0, 1.0);
        const sample: i16 = @intFromFloat(clamped * 32767.0);
        try writer.writeInt(i16, sample, .little);
    }
}

// ---------------------------------------------------------------------------
// Resampler — linear interpolation
// ---------------------------------------------------------------------------

/// Resample AudioBuffer to target_rate using linear interpolation.
/// Returns a new owned AudioBuffer. Caller must deinit.
pub fn resample(allocator: Allocator, src: AudioBuffer, target_rate: u32) !AudioBuffer {
    if (src.sample_rate == target_rate) {
        const out = try allocator.dupe(f32, src.samples);
        return AudioBuffer{ .samples = out, .sample_rate = target_rate, .allocator = allocator };
    }

    const ratio: f64 = @as(f64, @floatFromInt(src.sample_rate)) / @as(f64, @floatFromInt(target_rate));
    const out_len: usize = @intFromFloat(@as(f64, @floatFromInt(src.samples.len)) / ratio);
    const out = try allocator.alloc(f32, out_len);

    for (0..out_len) |i| {
        const pos: f64 = @as(f64, @floatFromInt(i)) * ratio;
        const idx: usize = @intFromFloat(pos);
        const frac: f32 = @floatCast(pos - @floor(pos));
        const a = src.samples[idx];
        const b = if (idx + 1 < src.samples.len) src.samples[idx + 1] else a;
        out[i] = a + frac * (b - a);
    }

    return AudioBuffer{ .samples = out, .sample_rate = target_rate, .allocator = allocator };
}

/// Convenience: read a WAV and resample to TARGET_SAMPLE_RATE (16 kHz) in one call.
pub fn readWavResampled(allocator: Allocator, path: []const u8) !AudioBuffer {
    var buf = try readWav(allocator, path);
    if (buf.sample_rate == TARGET_SAMPLE_RATE) return buf;
    var resampled = try resample(allocator, buf, TARGET_SAMPLE_RATE);
    buf.deinit();
    return resampled;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "AudioBuffer init and deinit" {
    const allocator = std.testing.allocator;
    var buf = try AudioBuffer.init(allocator, 16000, 16000);
    defer buf.deinit();
    try std.testing.expectEqual(@as(usize, 16000), buf.samples.len);
    try std.testing.expectApproxEqAbs(buf.duration_secs(), 1.0, 0.001);
}

test "resample passthrough" {
    const allocator = std.testing.allocator;
    var src = try AudioBuffer.init(allocator, 100, 16000);
    defer src.deinit();
    for (src.samples, 0..) |*s, i| s.* = @as(f32, @floatFromInt(i)) / 100.0;
    var out = try resample(allocator, src, 16000);
    defer out.deinit();
    try std.testing.expectEqual(src.samples.len, out.samples.len);
}
