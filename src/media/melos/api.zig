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
const theory = @import("theory.zig");

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

const StepBody = struct {
    base_prompt: ?[]const u8 = null,
    tempo_bpm: ?f32 = null,
    density: ?f32 = null,
    current_tick: ?u64 = null,
    seed: ?u64 = null,
    reset: ?bool = null,
};

fn chordName(w: anytype, st: *const live.LiveState, deg: u8) !void {
    const t = st.comp.tonic;
    const m = st.comp.mode;
    const root = theory.stepPc(t, m, deg);
    const third = @mod(@as(i32, theory.stepPc(t, m, @as(i32, deg) + 2)) - root, 12);
    const fifth = @mod(@as(i32, theory.stepPc(t, m, @as(i32, deg) + 4)) - root, 12);
    const q: []const u8 = if (fifth == 6) "dim" else if (third == 3) "m" else "";
    try w.print("{s}{s}", .{ note_names[root], q });
}

pub fn handleLiveStep(allocator: std.mem.Allocator, body: []const u8) !Result {
    var scratch: [8 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var sb = StepBody{};
    if (std.mem.trim(u8, body, " \r\n\t").len > 0) {
        sb = std.json.parseFromSliceLeaky(StepBody, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch
            return jsonError(allocator, 400, "invalid json");
    }

    var out_buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const w = fbs.writer();

    g_mutex.lock();
    defer g_mutex.unlock();
    // A client tick of 0 on a running set means "start a new set".
    const restart = g_live == null or (sb.reset orelse false) or
        (sb.current_tick != null and sb.current_tick.? == 0 and g_live.?.steps > 0);
    if (restart) {
        var attrs = types.MusicAttributes{};
        if (sb.tempo_bpm) |t| attrs.tempo_bpm = std.math.clamp(t, 40, 220);
        if (sb.density) |d| attrs.density = std.math.clamp(d, 0, 1);
        const seed = sb.seed orelse @as(u64, @bitCast(std.time.milliTimestamp()));
        g_live = live.LiveState.init(seed, sb.base_prompt, attrs);
    }
    const state = &g_live.?;
    var bo = generate.BarOut{};
    const bar_tick = state.step(&bo);

    try w.print("{{\"status\":\"ok\",\"bar\":{d},\"tick\":{d},\"next_tick\":{d},\"phrase\":\"{s}\",\"bar_in_phrase\":{d},\"chord\":\"", .{
        state.steps - 1, bar_tick, state.current_tick, bo.phrase.label(), bo.bar_in_phrase,
    });
    try chordName(w, state, bo.chord_deg);
    try w.print("\",\"key\":\"{s} {s}\",\"tempo_bpm\":{d:.1},\"notes\":[", .{ note_names[state.comp.tonic], @tagName(state.comp.mode), state.comp.p.tempo_bpm });
    var first = true;
    inline for (.{ "melody", "bass", "pad" }) |field| {
        const n = @field(bo, if (std.mem.eql(u8, field, "melody")) "mel_n" else if (std.mem.eql(u8, field, "bass")) "bass_n" else "pad_n");
        for (@field(bo, field)[0..n]) |nt| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{{\"pitch\":{d},\"velocity\":{d},\"start_tick\":{d},\"duration_ticks\":{d},\"channel\":{d}}}", .{ nt.pitch, nt.velocity, nt.start_tick, nt.duration_ticks, nt.channel });
        }
    }
    try w.writeAll("]}");
    return .{ .body = try allocator.dupe(u8, fbs.getWritten()) };
}

const ModBody = struct { prompt: ?[]const u8 = null };

pub fn handleLiveModulate(allocator: std.mem.Allocator, body: []const u8) !Result {
    var scratch: [4 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var mb = ModBody{};
    if (std.mem.trim(u8, body, " \r\n\t").len > 0) {
        mb = std.json.parseFromSliceLeaky(ModBody, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch
            return jsonError(allocator, 400, "invalid json");
    }
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_live == null) return jsonError(allocator, 409, "no live session: call live/step first");
    const state = &g_live.?;
    const prompt = mb.prompt orelse "";
    if (generate.emotionFromText(prompt)) |e| {
        const prof = theory.emotionProfile(e);
        state.comp.emotion = e;
        state.comp.setKey(state.comp.tonic, prof.mode);
        state.comp.p.tempo_bpm = prof.tempo;
        state.comp.p.density = prof.density;
        state.comp.p.energy = prof.energy;
        state.comp.p.syncopation = prof.syncopation;
        state.comp.p.seventh = prof.seventh;
        state.comp.p.clamp();
    }
    return .{ .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"ok\",\"summary\":\"{s}\",\"tempo_bpm\":{d:.1}}}", .{ @tagName(state.comp.emotion), state.comp.p.tempo_bpm }) };
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

test "live step advances ticks, differs per step, restarts on client tick 0" {
    const a = try handle(testing.allocator, .post, "/api/melos/live/step", "{\"seed\":9,\"reset\":true}");
    defer testing.allocator.free(a.body);
    var ticks: [6]u64 = undefined;
    var firsts: [6]i64 = undefined;
    for (0..6) |i| {
        const r = try handle(testing.allocator, .post, "/api/melos/live/step", "{}");
        defer testing.allocator.free(r.body);
        try testing.expectEqual(@as(u16, 200), r.status);
        const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.body, .{});
        defer p.deinit();
        ticks[i] = @intCast(p.value.object.get("tick").?.integer);
        const notes = p.value.object.get("notes").?.array.items;
        try testing.expect(notes.len >= 4);
        firsts[i] = notes[0].object.get("start_tick").?.integer;
    }
    for (ticks, 0..) |t, i| try testing.expectEqual(@as(u64, (i + 1) * 1920), t);
    try testing.expect(firsts[0] != firsts[1]);
    const rs = try handle(testing.allocator, .post, "/api/melos/live/step", "{\"current_tick\":0}");
    defer testing.allocator.free(rs.body);
    try testing.expect(std.mem.indexOf(u8, rs.body, "\"bar\":0,") != null);
}

test "modulate without a session is a JSON 409, with a session it responds" {
    g_mutex.lock();
    g_live = null;
    g_mutex.unlock();
    const r = try handle(testing.allocator, .post, "/api/melos/live/modulate", "{\"prompt\":\"bright\"}");
    defer testing.allocator.free(r.body);
    try testing.expectEqual(@as(u16, 409), r.status);
    try testing.expect(std.mem.indexOf(u8, r.body, "\"error\"") != null);
    const s = try handle(testing.allocator, .post, "/api/melos/live/step", "{\"seed\":1}");
    defer testing.allocator.free(s.body);
    const m = try handle(testing.allocator, .post, "/api/melos/live/modulate", "{\"prompt\":\"make it DARK\"}");
    defer testing.allocator.free(m.body);
    try testing.expectEqual(@as(u16, 200), m.status);
    try testing.expect(std.mem.indexOf(u8, m.body, "dark") != null);
}

fn hammer(ticks: *[8][40]u64, idx: usize) void {
    for (0..40) |i| {
        const r = handle(std.heap.page_allocator, .post, "/api/melos/live/step", "{}") catch return;
        defer std.heap.page_allocator.free(r.body);
        const k = std.mem.indexOf(u8, r.body, "\"tick\":") orelse return;
        const e = std.mem.indexOfScalarPos(u8, r.body, k + 7, ',') orelse return;
        ticks[idx][i] = std.fmt.parseInt(u64, r.body[k + 7 .. e], 10) catch return;
    }
}

test "concurrent live steps are race-free: every bar tick is unique and contiguous" {
    const a = try handle(testing.allocator, .post, "/api/melos/live/step", "{\"seed\":3,\"reset\":true}");
    testing.allocator.free(a.body);
    var ticks: [8][40]u64 = std.mem.zeroes([8][40]u64);
    var threads: [8]std.Thread = undefined;
    for (0..8) |i| threads[i] = try std.Thread.spawn(.{}, hammer, .{ &ticks, i });
    for (threads) |t| t.join();
    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    for (ticks) |row| for (row) |t| {
        try testing.expect(t >= 1920);
        try testing.expect(!seen.contains(t));
        try seen.put(t, {});
    };
    try testing.expectEqual(@as(usize, 320), seen.count());
    var k: u64 = 1;
    while (k <= 320) : (k += 1) try testing.expect(seen.contains(k * 1920));
}
