//! Melos HTTP route handlers.
//! Wired into the Arcis TierDispatcher (see src/api/tier.zig) via `handle`.
//! Endpoints:
//!   POST /api/melos/generate        {text?, seed?, bars?, attributes?{tempo_bpm,bars,emotion,density,key}}
//!   POST /api/melos/analyze
//!   POST /api/melos/live/step
//!   POST /api/melos/live/modulate   {prompt}
//!   GET  /api/melos/pedals
//!   POST /api/melos/pedals/submit

const std = @import("std");
const types = @import("types.zig");
const generate = @import("generate.zig");
const live = @import("live.zig");

pub const Result = struct {
    status: u16 = 200,
    body: []u8,
};

pub const Method = enum { get, post, other };

/// Shared live session (single performance).
var g_mutex: std.Thread.Mutex = .{};
var g_live: ?live.LiveState = null;

pub fn initLive(allocator: std.mem.Allocator) void {
    _ = allocator;
}

pub fn jsonError(allocator: std.mem.Allocator, status: u16, msg: []const u8) !Result {
    return .{ .status = status, .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"{s}\"}}", .{msg}) };
}

/// Route one request. Never leaves the caller without a JSON body.
pub fn handle(allocator: std.mem.Allocator, method: Method, path_in: []const u8, body: []const u8) !Result {
    const path = if (std.mem.indexOfScalar(u8, path_in, '?')) |q| path_in[0..q] else path_in;
    const post = method == .post;
    const get = method == .get;
    if (post and std.mem.eql(u8, path, "/api/melos/generate")) return handleGenerate(allocator, body);
    if (post and std.mem.eql(u8, path, "/api/melos/analyze")) return handleAnalyze(allocator, body);
    if (post and std.mem.eql(u8, path, "/api/melos/live/step")) return handleLiveStep(allocator, body);
    if (post and std.mem.eql(u8, path, "/api/melos/live/modulate")) return handleLiveModulate(allocator, body);
    if (get and std.mem.eql(u8, path, "/api/melos/pedals")) return .{ .body = try allocator.dupe(u8, "{\"pedals\":[]}") };
    if (post and std.mem.eql(u8, path, "/api/melos/pedals/submit")) return .{ .body = try allocator.dupe(u8, "{\"status\":\"submitted\"}") };
    return jsonError(allocator, 404, "melos route not found");
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

const note_names = [12][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

fn writeNotes(w: anytype, notes: []const types.MidiNote) !void {
    try w.writeByte('[');
    for (notes, 0..) |n, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"pitch\":{d},\"velocity\":{d},\"start_tick\":{d},\"duration_ticks\":{d},\"channel\":{d}}}", .{ n.pitch, n.velocity, n.start_tick, n.duration_ticks, n.channel });
    }
    try w.writeByte(']');
}

fn writePiece(w: anytype, piece: *const types.SymbolicPiece) !void {
    const a = piece.attributes;
    try w.writeAll("{\"ticks_per_quarter\":");
    try w.print("{d}", .{piece.ticks_per_quarter});
    try w.writeAll(",\"attributes\":{");
    if (a.key) |k| try w.print("\"key\":\"{s} {s}\",", .{ note_names[k.tonic], @tagName(k.mode) });
    if (a.emotion) |e| try w.print("\"emotion\":\"{s}\",", .{@tagName(e)});
    try w.print("\"tempo_bpm\":{d:.1},\"density\":{d:.2},\"bars\":{d}", .{ a.tempo_bpm orelse 120, a.density orelse 0.5, a.bars orelse 0 });
    try w.writeAll("},\"tracks\":[");
    for (piece.tracks, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"name\":\"{s}\",\"role\":\"{s}\",\"program\":{d},\"events\":", .{ t.name, @tagName(t.role), t.program });
        try writeNotes(w, t.events);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

fn parseKey(s: []const u8) ?types.Key {
    if (s.len == 0) return null;
    const letters = "C.D.EF.G.A.B";
    const idx = std.mem.indexOfScalar(u8, letters, std.ascii.toUpper(s[0])) orelse return null;
    if (letters[idx] == '.') return null;
    var pc: i32 = @intCast(idx);
    var i: usize = 1;
    if (i < s.len and (s[i] == '#' or s[i] == 'b')) {
        pc += if (s[i] == '#') 1 else -1;
        i += 1;
    }
    pc = @mod(pc, 12);
    while (i < s.len and s[i] == ' ') i += 1;
    var mode: types.Mode = .major;
    if (i < s.len) {
        mode = std.meta.stringToEnum(types.Mode, s[i..]) orelse return null;
    }
    return .{ .tonic = @intCast(pc), .mode = mode };
}

// ---------------------------------------------------------------------------
// generate
// ---------------------------------------------------------------------------

const GenBody = struct {
    text: ?[]const u8 = null,
    seed: ?u64 = null,
    bars: ?u16 = null,
    syncopation: ?f32 = null,
    humanize: ?f32 = null,
    attributes: ?struct {
        tempo_bpm: ?f32 = null,
        bars: ?u16 = null,
        emotion: ?[]const u8 = null,
        density: ?f32 = null,
        key: ?[]const u8 = null,
    } = null,
};

pub fn handleGenerate(allocator: std.mem.Allocator, body: []const u8) !Result {
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var gb = GenBody{};
    if (std.mem.trim(u8, body, " \r\n\t").len > 0) {
        gb = std.json.parseFromSliceLeaky(GenBody, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch
            return jsonError(allocator, 400, "invalid json");
    }
    var req = generate.GenerateRequest{
        .text = gb.text,
        .bars = gb.bars orelse 8,
        .seed = gb.seed orelse @as(u64, @intCast(@as(u64, @bitCast(std.time.milliTimestamp())))),
        .syncopation = if (gb.syncopation) |x| std.math.clamp(x, 0, 1) else null,
        .humanize = if (gb.humanize) |x| std.math.clamp(x, 0, 1) else null,
    };
    if (gb.attributes) |at| {
        var attrs = types.MusicAttributes{};
        if (at.tempo_bpm) |t| attrs.tempo_bpm = std.math.clamp(t, 40, 220);
        attrs.bars = at.bars;
        attrs.density = if (at.density) |d| std.math.clamp(d, 0, 1) else null;
        if (at.emotion) |e| attrs.emotion = std.meta.stringToEnum(types.Emotion, e);
        if (at.key) |k| attrs.key = parseKey(k);
        req.attributes = attrs;
    }
    var result = try generate.generateStub(allocator, req);
    defer result.deinit();

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    var total: usize = 0;
    for (result.piece.tracks) |t| total += t.events.len;
    try w.print("{{\"status\":\"ok\",\"notes\":{d},\"seed\":{d},\"piece\":", .{ total, req.seed });
    try writePiece(w, &result.piece);
    try w.writeByte('}');
    return .{ .body = try buf.toOwnedSlice() };
}

// ---------------------------------------------------------------------------
// analyze / live (stage 2 keeps the previous behaviour; reworked in later stages)
// ---------------------------------------------------------------------------

pub fn handleAnalyze(allocator: std.mem.Allocator, body: []const u8) !Result {
    _ = body;
    return .{ .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"ok\",\"summary\":\"stub\"}}", .{}) };
}

pub fn handleLiveStep(allocator: std.mem.Allocator, body: []const u8) !Result {
    _ = body;
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_live == null) {
        g_live = live.LiveState{
            .base_prompt = try std.heap.page_allocator.dupe(u8, "ambient"),
            .attributes = .{},
            .allocator = std.heap.page_allocator,
        };
    }
    const state = &g_live.?;
    const notes = try live.liveStep(allocator, state);
    defer allocator.free(notes);
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.writeAll("{\"status\":\"ok\",\"notes\":");
    try writeNotes(w, notes);
    try w.print(",\"tick\":{d}}}", .{state.current_tick});
    return .{ .body = try buf.toOwnedSlice() };
}

pub fn handleLiveModulate(allocator: std.mem.Allocator, body: []const u8) !Result {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_live == null) return jsonError(allocator, 409, "no live session: call live/step first");
    const state = &g_live.?;
    const new_attrs = try live.modulateFromPrompt(allocator, state, body);
    state.attributes = new_attrs;
    return .{ .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"ok\",\"summary\":\"modulated\",\"tempo\":{d}}}", .{state.attributes.tempo_bpm orelse 120}) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "generate returns parseable piece JSON with three tracks" {
    const r = try handle(testing.allocator, .post, "/api/melos/generate", "{\"seed\":5,\"bars\":8,\"attributes\":{\"emotion\":\"sad\",\"tempo_bpm\":90,\"key\":\"D dorian\"}}");
    defer testing.allocator.free(r.body);
    try testing.expectEqual(@as(u16, 200), r.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.body, .{});
    defer parsed.deinit();
    const piece = parsed.value.object.get("piece").?.object;
    try testing.expectEqual(@as(usize, 3), piece.get("tracks").?.array.items.len);
    try testing.expectEqualStrings("D dorian", piece.get("attributes").?.object.get("key").?.string);
    const ev0 = piece.get("tracks").?.array.items[0].object.get("events").?.array.items[0].object;
    try testing.expect(ev0.get("pitch") != null and ev0.get("start_tick") != null and ev0.get("duration_ticks") != null);
}

test "generate accepts empty body and rejects invalid json with a JSON 400" {
    const ok = try handle(testing.allocator, .post, "/api/melos/generate", "");
    defer testing.allocator.free(ok.body);
    try testing.expectEqual(@as(u16, 200), ok.status);
    const bad = try handle(testing.allocator, .post, "/api/melos/generate", "{not json");
    defer testing.allocator.free(bad.body);
    try testing.expectEqual(@as(u16, 400), bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.body, "\"error\"") != null);
}

test "unknown route and wrong method return JSON 404" {
    const r = try handle(testing.allocator, .get, "/api/melos/generate", "");
    defer testing.allocator.free(r.body);
    try testing.expectEqual(@as(u16, 404), r.status);
}

test "key parser" {
    try testing.expectEqual(types.Key{ .tonic = 2, .mode = .dorian }, parseKey("D dorian").?);
    try testing.expectEqual(types.Key{ .tonic = 10, .mode = .minor }, parseKey("Bb minor").?);
    try testing.expectEqual(types.Key{ .tonic = 6, .mode = .major }, parseKey("F#").?);
    try testing.expect(parseKey("H major") == null);
}
