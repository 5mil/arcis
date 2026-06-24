//! mel.zig — STFT → power spectrum → mel filterbank → log-mel spectrogram
//! Phase 5 — src/media/
//! Depends on: src/core/tensor.zig, audio.zig
//! Mirrors: src/infer/rope.zig (precomputed frequency tables)

const std = @import("std");
const Allocator = std.mem.Allocator;
const AudioBuffer = @import("audio.zig").AudioBuffer;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub const MelConfig = struct {
    n_fft:       usize = 400,     // FFT window size (25 ms at 16 kHz)
    hop_length:  usize = 160,     // hop size (10 ms at 16 kHz)
    n_mels:      usize = 80,      // mel bins (128 for large Whisper)
    sample_rate: u32   = 16_000,
    f_min:       f32   = 0.0,
    f_max:       f32   = 8_000.0,
};

// ---------------------------------------------------------------------------
// Mel spectrogram output
// ---------------------------------------------------------------------------

/// Owned [n_frames x n_mels] f32 log-mel spectrogram.
pub const MelSpectrogram = struct {
    data:     []f32,   // row-major [n_frames * n_mels]
    n_frames: usize,
    n_mels:   usize,
    allocator: Allocator,

    pub fn deinit(self: *MelSpectrogram) void {
        self.allocator.free(self.data);
    }

    pub fn frame(self: MelSpectrogram, i: usize) []const f32 {
        const base = i * self.n_mels;
        return self.data[base .. base + self.n_mels];
    }
};

// ---------------------------------------------------------------------------
// Hann window
// ---------------------------------------------------------------------------

fn hannWindow(allocator: Allocator, size: usize) ![]f32 {
    const w = try allocator.alloc(f32, size);
    const n: f32 = @floatFromInt(size);
    for (w, 0..) |*v, i| {
        const x: f32 = @floatFromInt(i);
        v.* = 0.5 * (1.0 - @cos(2.0 * std.math.pi * x / n));
    }
    return w;
}

// ---------------------------------------------------------------------------
// Real FFT (DFT naive — replace with FFTW-style radix-2 in optimisation pass)
// ---------------------------------------------------------------------------

/// Compute real DFT magnitude squared for a windowed frame.
/// output: [(n_fft/2 + 1)] power values.
fn powerSpectrum(frame_buf: []const f32, n_fft: usize, out: []f32) void {
    const n_bins = n_fft / 2 + 1;
    std.debug.assert(out.len >= n_bins);
    const N: f32 = @floatFromInt(n_fft);
    for (0..n_bins) |k| {
        var re: f32 = 0.0;
        var im: f32 = 0.0;
        const kf: f32 = @floatFromInt(k);
        for (0..@min(frame_buf.len, n_fft)) |n| {
            const nf: f32 = @floatFromInt(n);
            const angle = 2.0 * std.math.pi * kf * nf / N;
            re += frame_buf[n] * @cos(angle);
            im -= frame_buf[n] * @sin(angle);
        }
        out[k] = re * re + im * im;
    }
}

// ---------------------------------------------------------------------------
// Mel filterbank
// ---------------------------------------------------------------------------

/// Hz to mel (HTK formula).
fn hzToMel(hz: f32) f32 {
    return 2595.0 * std.math.log10(1.0 + hz / 700.0);
}

/// Mel to Hz.
fn melToHz(mel: f32) f32 {
    return 700.0 * (std.math.pow(f32, 10.0, mel / 2595.0) - 1.0);
}

/// Build [n_mels x (n_fft/2+1)] triangular mel filterbank matrix.
/// Caller owns returned slice.
fn buildMelFilterbank(
    allocator: Allocator,
    cfg: MelConfig,
) ![]f32 {
    const n_bins  = cfg.n_fft / 2 + 1;
    const n_mels  = cfg.n_mels;
    const mat     = try allocator.alloc(f32, n_mels * n_bins);
    @memset(mat, 0);

    const mel_min = hzToMel(cfg.f_min);
    const mel_max = hzToMel(cfg.f_max);
    const mel_step = (mel_max - mel_min) / @as(f32, @floatFromInt(n_mels + 1));

    // Centre frequencies in Hz for each of the n_mels+2 mel points.
    const centers = try allocator.alloc(f32, n_mels + 2);
    defer allocator.free(centers);
    for (centers, 0..) |*c, i| {
        c.* = melToHz(mel_min + @as(f32, @floatFromInt(i)) * mel_step);
    }

    const sr: f32 = @floatFromInt(cfg.sample_rate);
    for (0..n_mels) |m| {
        const f_left   = centers[m];
        const f_center = centers[m + 1];
        const f_right  = centers[m + 2];
        for (0..n_bins) |k| {
            const hz = @as(f32, @floatFromInt(k)) * sr / @as(f32, @floatFromInt(cfg.n_fft));
            var val: f32 = 0.0;
            if (hz >= f_left and hz <= f_center)
                val = (hz - f_left) / (f_center - f_left)
            else if (hz > f_center and hz <= f_right)
                val = (f_right - hz) / (f_right - f_center);
            mat[m * n_bins + k] = val;
        }
    }
    return mat;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Compute log-mel spectrogram from an AudioBuffer.
/// AudioBuffer must already be at cfg.sample_rate (use audio.resample first).
/// Returns owned MelSpectrogram. Caller must call deinit().
pub fn compute(allocator: Allocator, buf: AudioBuffer, cfg: MelConfig) !MelSpectrogram {
    const n_bins   = cfg.n_fft / 2 + 1;
    const n_frames = if (buf.samples.len >= cfg.n_fft)
        (buf.samples.len - cfg.n_fft) / cfg.hop_length + 1
    else 0;

    if (n_frames == 0) return error.AudioTooShort;

    const window  = try hannWindow(allocator, cfg.n_fft);
    defer allocator.free(window);

    const mel_fb  = try buildMelFilterbank(allocator, cfg);
    defer allocator.free(mel_fb);

    const data    = try allocator.alloc(f32, n_frames * cfg.n_mels);
    errdefer allocator.free(data);

    var power_buf = try allocator.alloc(f32, n_bins);
    defer allocator.free(power_buf);
    var frame_buf = try allocator.alloc(f32, cfg.n_fft);
    defer allocator.free(frame_buf);

    for (0..n_frames) |f| {
        const start = f * cfg.hop_length;
        // Apply Hann window.
        for (0..cfg.n_fft) |i| {
            frame_buf[i] = buf.samples[start + i] * window[i];
        }
        // Power spectrum.
        powerSpectrum(frame_buf, cfg.n_fft, power_buf);
        // Mel filterbank dot product.
        for (0..cfg.n_mels) |m| {
            var mel_val: f32 = 0.0;
            for (0..n_bins) |k| {
                mel_val += mel_fb[m * n_bins + k] * power_buf[k];
            }
            // Log compression (clip to 1e-10 floor).
            data[f * cfg.n_mels + m] = std.math.log10(@max(mel_val, 1e-10));
        }
    }

    return MelSpectrogram{
        .data     = data,
        .n_frames = n_frames,
        .n_mels   = cfg.n_mels,
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "mel config defaults" {
    const cfg = MelConfig{};
    try std.testing.expectEqual(@as(usize, 80), cfg.n_mels);
    try std.testing.expectEqual(@as(usize, 400), cfg.n_fft);
}

test "hann window symmetry" {
    const allocator = std.testing.allocator;
    const w = try hannWindow(allocator, 8);
    defer allocator.free(w);
    try std.testing.expectApproxEqAbs(w[0], 0.0, 1e-6);
}
