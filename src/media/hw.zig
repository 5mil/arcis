//! hw.zig — hardware audio I/O: ALSA PCM, MIDI device enumeration, USB audio
//! Studio module — src/media/
//! Depends on: audio.zig
//! Platform: Linux (zigllm-os). Uses raw /dev and /sys interfaces — no libasound.

const std = @import("std");
const Allocator = std.mem.Allocator;
const audio = @import("audio.zig");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const ALSA_PCM_PATH = "/dev/snd/pcmC0D0c"; // capture device 0
pub const ALSA_PCM_PLAY_PATH = "/dev/snd/pcmC0D0p"; // playback device 0
pub const MIDI_DEVICE_DIR = "/dev/snd";
pub const SYS_SOUND_CLASS = "/sys/class/sound";
pub const MAX_HW_DEVICES = 16;
pub const HW_FRAME_SIZE = 1024; // frames per read/write chunk

// ---------------------------------------------------------------------------
// Device kinds
// ---------------------------------------------------------------------------

pub const DeviceKind = enum {
    pcm_capture,
    pcm_playback,
    midi,
    usb_audio,
};

pub const HwDevice = struct {
    kind: DeviceKind,
    /// Null-terminated path, e.g. "/dev/snd/pcmC1D0c"
    path: [64]u8,
    path_len: usize,
    /// Human-readable name from /sys/class/sound/<dev>/device/name, if available.
    name: [128]u8,
    name_len: usize,
    card: u8,
    device: u8,

    pub fn pathSlice(self: *const HwDevice) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn nameSlice(self: *const HwDevice) []const u8 {
        return self.name[0..self.name_len];
    }
};

// ---------------------------------------------------------------------------
// Device enumeration
// ---------------------------------------------------------------------------

/// Enumerate sound devices under /sys/class/sound.
/// Returns a slice of HwDevice (owned by caller via allocator).
/// Covers PCM capture, PCM playback, and MIDI.
pub fn enumerateDevices(allocator: Allocator) ![]HwDevice {
    var list = std.ArrayList(HwDevice).init(allocator);
    errdefer list.deinit();

    const dir = std.fs.openDirAbsolute(SYS_SOUND_CLASS, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return list.toOwnedSlice();
        return err;
    };
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (list.items.len >= MAX_HW_DEVICES) break;

        var dev = HwDevice{
            .kind = .pcm_capture,
            .path = [_]u8{0} ** 64,
            .path_len = 0,
            .name = [_]u8{0} ** 128,
            .name_len = 0,
            .card = 0,
            .device = 0,
        };

        const n = entry.name;

        if (std.mem.startsWith(u8, n, "pcm")) {
            const is_capture = std.mem.endsWith(u8, n, "c");
            dev.kind = if (is_capture) .pcm_capture else .pcm_playback;
            const dev_path = try std.fmt.bufPrint(&dev.path, "/dev/snd/{s}", .{n});
            dev.path_len = dev_path.len;
            parseCardDevice(n[3..], &dev.card, &dev.device);
        } else if (std.mem.startsWith(u8, n, "midi")) {
            dev.kind = .midi;
            const dev_path = try std.fmt.bufPrint(&dev.path, "/dev/snd/{s}", .{n});
            dev.path_len = dev_path.len;
            parseCardDevice(n[4..], &dev.card, &dev.device);
        } else {
            continue;
        }

        readSysName(SYS_SOUND_CLASS, n, &dev.name, &dev.name_len);
        if (isUsbAudio(SYS_SOUND_CLASS, n)) dev.kind = .usb_audio;

        try list.append(dev);
    }

    return list.toOwnedSlice();
}

fn parseCardDevice(s: []const u8, card: *u8, device: *u8) void {
    card.* = 0;
    device.* = 0;
    var i: usize = 0;
    if (i < s.len and (s[i] == 'C' or s[i] == 'c')) i += 1;
    var card_val: u8 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1)
        card_val = card_val * 10 + (s[i] - '0');
    card.* = card_val;
    if (i < s.len and (s[i] == 'D' or s[i] == 'd')) i += 1;
    var dev_val: u8 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1)
        dev_val = dev_val * 10 + (s[i] - '0');
    device.* = dev_val;
}

fn readSysName(base: []const u8, dev_entry: []const u8, out: *[128]u8, out_len: *usize) void {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/device/name", .{ base, dev_entry }) catch return;
    const f = std.fs.openFileAbsolute(path, .{}) catch return;
    defer f.close();
    const n = f.read(out[0..127]) catch return;
    out_len.* = if (n > 0 and out[n - 1] == '\n') n - 1 else n;
}

fn isUsbAudio(base: []const u8, dev_entry: []const u8) bool {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/device/subsystem", .{ base, dev_entry }) catch return false;
    const f = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer f.close();
    var buf: [64]u8 = undefined;
    const n = f.read(&buf) catch return false;
    return std.mem.indexOf(u8, buf[0..n], "usb") != null;
}

// ---------------------------------------------------------------------------
// ALSA raw PCM capture
// ---------------------------------------------------------------------------

pub const PcmCapture = struct {
    file: std.fs.File,
    sample_rate: u32,
    channels: u8,
    allocator: Allocator,

    pub fn open(allocator: Allocator, path: []const u8, sample_rate: u32, channels: u8) !PcmCapture {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
        return PcmCapture{
            .file = file,
            .sample_rate = sample_rate,
            .channels = channels,
            .allocator = allocator,
        };
    }

    pub fn close(self: *PcmCapture) void {
        self.file.close();
    }

    pub fn readChunk(self: *PcmCapture) !audio.AudioBuffer {
        const n_samples = HW_FRAME_SIZE * self.channels;
        const raw = try self.allocator.alloc(i16, n_samples);
        defer self.allocator.free(raw);

        const bytes = std.mem.sliceAsBytes(raw);
        const n_read = try self.file.read(bytes);
        const frames_read = n_read / (2 * self.channels);

        const out = try self.allocator.alloc(f32, frames_read);
        const ch_f: f32 = @floatFromInt(self.channels);
        for (0..frames_read) |i| {
            var sum: f32 = 0.0;
            for (0..self.channels) |c| {
                sum += @as(f32, @floatFromInt(raw[i * self.channels + c]));
            }
            out[i] = (sum / ch_f) / 32768.0;
        }

        return audio.AudioBuffer{ .samples = out, .sample_rate = self.sample_rate, .allocator = self.allocator };
    }
};

// ---------------------------------------------------------------------------
// ALSA raw PCM playback
// ---------------------------------------------------------------------------

pub const PcmPlayback = struct {
    file: std.fs.File,
    sample_rate: u32,

    pub fn open(path: []const u8, sample_rate: u32) !PcmPlayback {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .write_only });
        return PcmPlayback{ .file = file, .sample_rate = sample_rate };
    }

    pub fn close(self: *PcmPlayback) void {
        self.file.close();
    }

    pub fn writeBuffer(self: *PcmPlayback, buf: audio.AudioBuffer) !void {
        for (buf.samples) |s| {
            const clamped = std.math.clamp(s, -1.0, 1.0);
            const sample: i16 = @intFromFloat(clamped * 32767.0);
            try self.file.writer().writeInt(i16, sample, .little);
        }
    }
};

// ---------------------------------------------------------------------------
// MIDI reader
// ---------------------------------------------------------------------------

pub const MidiEvent = struct {
    status: u8,
    data1: u8,
    data2: u8,

    pub fn isNoteOn(self: MidiEvent) bool {
        return (self.status & 0xF0) == 0x90 and self.data2 > 0;
    }

    pub fn isNoteOff(self: MidiEvent) bool {
        return (self.status & 0xF0) == 0x80 or
            ((self.status & 0xF0) == 0x90 and self.data2 == 0);
    }

    pub fn channel(self: MidiEvent) u4 {
        return @truncate(self.status & 0x0F);
    }

    pub fn noteHz(self: MidiEvent) f32 {
        const diff: f32 = @as(f32, @floatFromInt(self.data1)) - 69.0;
        return 440.0 * std.math.pow(f32, 2.0, diff / 12.0);
    }
};

pub const MidiReader = struct {
    file: std.fs.File,

    pub fn open(path: []const u8) !MidiReader {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
        return MidiReader{ .file = file };
    }

    pub fn close(self: *MidiReader) void {
        self.file.close();
    }

    pub fn readEvent(self: *MidiReader) !?MidiEvent {
        var buf: [3]u8 = undefined;
        const n = self.file.read(&buf) catch return null;
        if (n < 3) return null;
        return MidiEvent{ .status = buf[0], .data1 = buf[1], .data2 = buf[2] };
    }
};

// ---------------------------------------------------------------------------
// HwContext
// ---------------------------------------------------------------------------

pub const HwConfig = struct {
    capture_path: []const u8 = ALSA_PCM_PATH,
    playback_path: []const u8 = ALSA_PCM_PLAY_PATH,
    sample_rate: u32 = 44_100,
    channels: u8 = 2,
    midi_path: ?[]const u8 = null,
};

pub const HwContext = struct {
    config: HwConfig,
    capture: ?PcmCapture,
    playback: ?PcmPlayback,
    midi: ?MidiReader,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: HwConfig) HwContext {
        return .{
            .config = config,
            .capture = null,
            .playback = null,
            .midi = null,
            .allocator = allocator,
        };
    }

    pub fn openCapture(self: *HwContext) !void {
        self.capture = try PcmCapture.open(
            self.allocator,
            self.config.capture_path,
            self.config.sample_rate,
            self.config.channels,
        );
    }

    pub fn openPlayback(self: *HwContext) !void {
        self.playback = try PcmPlayback.open(
            self.config.playback_path,
            self.config.sample_rate,
        );
    }

    pub fn openMidi(self: *HwContext) !void {
        const path = self.config.midi_path orelse return error.NoMidiPath;
        self.midi = try MidiReader.open(path);
    }

    pub fn deinit(self: *HwContext) void {
        if (self.capture) |*c| c.close();
        if (self.playback) |*p| p.close();
        if (self.midi) |*m| m.close();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseCardDevice basic" {
    var card: u8 = 0;
    var device: u8 = 0;
    parseCardDevice("C1D2c", &card, &device);
    try std.testing.expectEqual(@as(u8, 1), card);
    try std.testing.expectEqual(@as(u8, 2), device);
}

test "MidiEvent noteHz A4" {
    const ev = MidiEvent{ .status = 0x90, .data1 = 69, .data2 = 100 };
    try std.testing.expect(ev.isNoteOn());
    try std.testing.expectApproxEqAbs(ev.noteHz(), 440.0, 0.01);
}

test "MidiEvent noteHz middle C" {
    const ev = MidiEvent{ .status = 0x90, .data1 = 60, .data2 = 80 };
    try std.testing.expectApproxEqAbs(ev.noteHz(), 261.63, 0.1);
}

test "MidiEvent channel" {
    const ev = MidiEvent{ .status = 0x93, .data1 = 60, .data2 = 80 };
    try std.testing.expectEqual(@as(u4, 3), ev.channel());
}

test "HwConfig defaults" {
    const cfg = HwConfig{};
    try std.testing.expectEqual(@as(u32, 44_100), cfg.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), cfg.channels);
    try std.testing.expect(cfg.midi_path == null);
}

test "HwContext init does not open devices" {
    const allocator = std.testing.allocator;
    var ctx = HwContext.init(allocator, .{});
    defer ctx.deinit();
    try std.testing.expect(ctx.capture == null);
    try std.testing.expect(ctx.playback == null);
    try std.testing.expect(ctx.midi == null);
}
