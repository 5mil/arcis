//! stream.zig — streaming audio engine: ring buffer, local file streaming,
//!              HTTP audio stream ingest, Icecast/Shoutcast connector
//! Studio module — src/media/
//! Depends on: audio.zig, hw.zig

const std = @import("std");
const Allocator = std.mem.Allocator;
const audio = @import("audio.zig");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const RING_CAPACITY_FRAMES = 65_536; // ~1.5s at 44.1kHz
pub const CHUNK_FRAMES = 1024;
pub const HTTP_RECV_BUF = 4096;
pub const MAX_URL_LEN = 512;
pub const ICY_META_INTERVAL = 16_000;

// ---------------------------------------------------------------------------
// RingBuffer — lock-free SPSC f32 ring
// ---------------------------------------------------------------------------

pub const RingBuffer = struct {
    buf: []f32,
    capacity: usize,
    write_pos: usize,
    read_pos: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !RingBuffer {
        const buf = try allocator.alloc(f32, capacity);
        @memset(buf, 0.0);
        return RingBuffer{
            .buf = buf,
            .capacity = capacity,
            .write_pos = 0,
            .read_pos = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RingBuffer) void {
        self.allocator.free(self.buf);
    }

    pub fn available(self: *const RingBuffer) usize {
        return (self.write_pos -% self.read_pos) % self.capacity;
    }

    pub fn freeSpace(self: *const RingBuffer) usize {
        return self.capacity - 1 - self.available();
    }

    pub fn write(self: *RingBuffer, samples: []const f32) usize {
        const free = self.freeSpace();
        const n = @min(samples.len, free);
        for (samples[0..n], 0..) |s, i| {
            self.buf[(self.write_pos + i) % self.capacity] = s;
        }
        self.write_pos = (self.write_pos + n) % self.capacity;
        return n;
    }

    pub fn read(self: *RingBuffer, dst: []f32) usize {
        const avail = self.available();
        const n = @min(dst.len, avail);
        for (0..n) |i| {
            dst[i] = self.buf[(self.read_pos + i) % self.capacity];
        }
        self.read_pos = (self.read_pos + n) % self.capacity;
        return n;
    }

    pub fn reset(self: *RingBuffer) void {
        self.write_pos = 0;
        self.read_pos = 0;
        @memset(self.buf, 0.0);
    }
};

// ---------------------------------------------------------------------------
// StreamKind
// ---------------------------------------------------------------------------

pub const StreamKind = enum {
    local_file,
    http,
    hw_capture,
};

// ---------------------------------------------------------------------------
// LocalFileStream
// ---------------------------------------------------------------------------

pub const LocalFileStream = struct {
    file: std.fs.File,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    data_start: u64,
    data_end: u64,
    pos: u64,
    allocator: Allocator,

    pub fn open(allocator: Allocator, path: []const u8) !LocalFileStream {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();

        var hdr: [44]u8 = undefined;
        const n = try file.readAll(&hdr);
        if (n < 44) return error.InvalidWavHeader;
        if (!std.mem.eql(u8, hdr[0..4], "RIFF")) return error.NotRiff;
        if (!std.mem.eql(u8, hdr[8..12], "WAVE")) return error.NotWave;

        const channels = std.mem.readInt(u16, hdr[22..24], .little);
        const sample_rate = std.mem.readInt(u32, hdr[24..28], .little);
        const bits = std.mem.readInt(u16, hdr[34..36], .little);
        const data_size = std.mem.readInt(u32, hdr[40..44], .little);

        return LocalFileStream{
            .file = file,
            .sample_rate = sample_rate,
            .channels = channels,
            .bits = bits,
            .data_start = 44,
            .data_end = 44 + data_size,
            .pos = 44,
            .allocator = allocator,
        };
    }

    pub fn close(self: *LocalFileStream) void {
        self.file.close();
    }

    pub fn nextChunk(self: *LocalFileStream) !?audio.AudioBuffer {
        if (self.pos >= self.data_end) return null;

        const bytes_per_frame: u64 = self.channels * (self.bits / 8);
        const remaining_frames: u64 = (self.data_end - self.pos) / bytes_per_frame;
        const frames = @min(@as(u64, CHUNK_FRAMES), remaining_frames);
        if (frames == 0) return null;

        const n_samples = frames * self.channels;
        const raw = try self.allocator.alloc(i16, n_samples);
        defer self.allocator.free(raw);

        try self.file.seekTo(self.pos);
        const bytes_read = try self.file.read(std.mem.sliceAsBytes(raw));
        const frames_read = bytes_read / (self.channels * 2);
        self.pos += bytes_read;

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

    pub fn rewind(self: *LocalFileStream) void {
        self.pos = self.data_start;
    }
};

// ---------------------------------------------------------------------------
// HttpStream — HTTP/1.0 with ICY metadata
// ---------------------------------------------------------------------------

pub const IcyMeta = struct {
    title: [256]u8,
    title_len: usize,
    url: [256]u8,
    url_len: usize,

    pub fn titleSlice(self: *const IcyMeta) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const HttpStreamConfig = struct {
    host: []const u8,
    port: u16 = 80,
    path: []const u8 = "/",
    icy_metadata: bool = true,
};

pub const HttpStream = struct {
    stream: std.net.Stream,
    config: HttpStreamConfig,
    allocator: Allocator,
    icy_offset: usize,
    last_meta: IcyMeta,
    recv_buf: [HTTP_RECV_BUF]u8,
    recv_len: usize,
    recv_pos: usize,

    pub fn connect(allocator: Allocator, config: HttpStreamConfig) !HttpStream {
        const addr = try std.net.Address.resolveIp(config.host, config.port);
        const stream = try std.net.tcpConnectToAddress(addr);
        errdefer stream.close();

        var req_buf: [1024]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf,
            "GET {s} HTTP/1.0\r\nHost: {s}\r\nIcy-MetaData: {d}\r\nConnection: close\r\n\r\n",
            .{ config.path, config.host, @intFromBool(config.icy_metadata) });
        try stream.writeAll(req);

        var hdr_buf: [4096]u8 = undefined;
        var hdr_pos: usize = 0;
        while (hdr_pos < hdr_buf.len) {
            const n = try stream.read(hdr_buf[hdr_pos .. hdr_pos + 1]);
            if (n == 0) break;
            hdr_pos += 1;
            if (hdr_pos >= 4 and std.mem.eql(u8, hdr_buf[hdr_pos - 4 .. hdr_pos], "\r\n\r\n")) break;
        }

        return HttpStream{
            .stream = stream,
            .config = config,
            .allocator = allocator,
            .icy_offset = 0,
            .last_meta = .{
                .title = [_]u8{0} ** 256,
                .title_len = 0,
                .url = [_]u8{0} ** 256,
                .url_len = 0,
            },
            .recv_buf = undefined,
            .recv_len = 0,
            .recv_pos = 0,
        };
    }

    pub fn close(self: *HttpStream) void {
        self.stream.close();
    }

    pub fn readRaw(self: *HttpStream, n_bytes: usize) ![]u8 {
        const out = try self.allocator.alloc(u8, n_bytes);
        errdefer self.allocator.free(out);
        var out_pos: usize = 0;

        while (out_pos < n_bytes) {
            if (self.recv_pos >= self.recv_len) {
                const n = try self.stream.read(&self.recv_buf);
                if (n == 0) break;
                self.recv_len = n;
                self.recv_pos = 0;
            }

            if (self.config.icy_metadata) {
                const until_meta = ICY_META_INTERVAL - self.icy_offset;
                const avail = self.recv_len - self.recv_pos;
                const copy = @min(until_meta, @min(avail, n_bytes - out_pos));
                @memcpy(out[out_pos .. out_pos + copy], self.recv_buf[self.recv_pos .. self.recv_pos + copy]);
                out_pos += copy;
                self.recv_pos += copy;
                self.icy_offset += copy;
                if (self.icy_offset >= ICY_META_INTERVAL) {
                    self.icy_offset = 0;
                    try self.consumeIcyBlock();
                }
            } else {
                const avail = self.recv_len - self.recv_pos;
                const copy = @min(avail, n_bytes - out_pos);
                @memcpy(out[out_pos .. out_pos + copy], self.recv_buf[self.recv_pos .. self.recv_pos + copy]);
                out_pos += copy;
                self.recv_pos += copy;
            }
        }

        return self.allocator.realloc(out, out_pos) catch out;
    }

    fn consumeIcyBlock(self: *HttpStream) !void {
        var len_byte: [1]u8 = undefined;
        _ = try self.stream.read(&len_byte);
        const meta_len = @as(usize, len_byte[0]) * 16;
        if (meta_len == 0) return;
        var meta_buf: [512]u8 = undefined;
        const actual = @min(meta_len, meta_buf.len);
        _ = try self.stream.read(meta_buf[0..actual]);
        parseIcyMeta(meta_buf[0..actual], &self.last_meta);
    }

    pub fn parseIcyMeta(raw: []const u8, meta: *IcyMeta) void {
        if (std.mem.indexOf(u8, raw, "StreamTitle='")) |start| {
            const s = start + 13;
            if (std.mem.indexOfPos(u8, raw, s, "';")) |end| {
                const len = @min(end - s, meta.title.len - 1);
                @memcpy(meta.title[0..len], raw[s .. s + len]);
                meta.title_len = len;
            }
        }
        if (std.mem.indexOf(u8, raw, "StreamUrl='")) |start| {
            const s = start + 11;
            if (std.mem.indexOfPos(u8, raw, s, "';")) |end| {
                const len = @min(end - s, meta.url.len - 1);
                @memcpy(meta.url[0..len], raw[s .. s + len]);
                meta.url_len = len;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// AudioStream — unified streaming session
// ---------------------------------------------------------------------------

pub const AudioStream = struct {
    kind: StreamKind,
    ring: RingBuffer,
    sample_rate: u32,
    allocator: Allocator,

    pub fn initLocal(allocator: Allocator, sample_rate: u32) !AudioStream {
        return AudioStream{
            .kind = .local_file,
            .ring = try RingBuffer.init(allocator, RING_CAPACITY_FRAMES),
            .sample_rate = sample_rate,
            .allocator = allocator,
        };
    }

    pub fn initHttp(allocator: Allocator, sample_rate: u32) !AudioStream {
        return AudioStream{
            .kind = .http,
            .ring = try RingBuffer.init(allocator, RING_CAPACITY_FRAMES),
            .sample_rate = sample_rate,
            .allocator = allocator,
        };
    }

    pub fn initHwCapture(allocator: Allocator, sample_rate: u32) !AudioStream {
        return AudioStream{
            .kind = .hw_capture,
            .ring = try RingBuffer.init(allocator, RING_CAPACITY_FRAMES),
            .sample_rate = sample_rate,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AudioStream) void {
        self.ring.deinit();
    }

    pub fn push(self: *AudioStream, buf: audio.AudioBuffer) usize {
        return self.ring.write(buf.samples);
    }

    pub fn pull(self: *AudioStream, n_frames: usize) !audio.AudioBuffer {
        const out = try self.allocator.alloc(f32, n_frames);
        const n_read = self.ring.read(out);
        const trimmed = try self.allocator.realloc(out, n_read);
        return audio.AudioBuffer{ .samples = trimmed, .sample_rate = self.sample_rate, .allocator = self.allocator };
    }

    pub fn availableFrames(self: *const AudioStream) usize {
        return self.ring.available();
    }

    pub fn reset(self: *AudioStream) void {
        self.ring.reset();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "RingBuffer write and read" {
    const allocator = std.testing.allocator;
    var ring = try RingBuffer.init(allocator, 16);
    defer ring.deinit();

    const data = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    const written = ring.write(&data);
    try std.testing.expectEqual(@as(usize, 4), written);
    try std.testing.expectEqual(@as(usize, 4), ring.available());

    var out: [4]f32 = undefined;
    const n = ring.read(&out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectApproxEqAbs(out[0], 0.1, 0.0001);
    try std.testing.expectApproxEqAbs(out[3], 0.4, 0.0001);
    try std.testing.expectEqual(@as(usize, 0), ring.available());
}

test "RingBuffer wraps correctly" {
    const allocator = std.testing.allocator;
    var ring = try RingBuffer.init(allocator, 8);
    defer ring.deinit();

    const fill = [_]f32{ 1, 2, 3, 4, 5, 6, 7 };
    _ = ring.write(&fill);
    var drain: [4]f32 = undefined;
    _ = ring.read(&drain);
    const more = [_]f32{ 8, 9, 10, 11 };
    const w = ring.write(&more);
    try std.testing.expectEqual(@as(usize, 4), w);
    try std.testing.expectEqual(@as(usize, 7), ring.available());
}

test "RingBuffer reset" {
    const allocator = std.testing.allocator;
    var ring = try RingBuffer.init(allocator, 16);
    defer ring.deinit();
    const d = [_]f32{ 1.0, 2.0 };
    _ = ring.write(&d);
    ring.reset();
    try std.testing.expectEqual(@as(usize, 0), ring.available());
}

test "AudioStream push and pull" {
    const allocator = std.testing.allocator;
    var stream = try AudioStream.initLocal(allocator, 44_100);
    defer stream.deinit();

    const samples = try allocator.alloc(f32, 512);
    for (samples, 0..) |*s, i| s.* = @as(f32, @floatFromInt(i)) / 512.0;
    const buf = audio.AudioBuffer{ .samples = samples, .sample_rate = 44_100, .allocator = allocator };
    defer buf.deinit();

    const pushed = stream.push(buf);
    try std.testing.expectEqual(@as(usize, 512), pushed);

    var pulled = try stream.pull(256);
    defer pulled.deinit();
    try std.testing.expectEqual(@as(usize, 256), pulled.samples.len);
    try std.testing.expectEqual(@as(usize, 256), stream.availableFrames());
}

test "parseIcyMeta title extraction" {
    const raw = "StreamTitle='Test Song - Artist';StreamUrl='';";
    var meta = IcyMeta{
        .title = [_]u8{0} ** 256,
        .title_len = 0,
        .url = [_]u8{0} ** 256,
        .url_len = 0,
    };
    HttpStream.parseIcyMeta(raw, &meta);
    try std.testing.expectEqualStrings("Test Song - Artist", meta.titleSlice());
}
