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
const pedals = @import("pedals.zig");

pub const Result = struct {
    status: u16 = 200,
    body: []u8,
};

pub const Method = enum { get, post, other };

/// Shared live session (single performance).
var g_mutex: std.Thread.Mutex = .{};
var g_live: ?live.LiveState = null;
var g_pedals: pedals.PedalBoard = .{};
var g_last_mod_ms: i64 = 0;
var g_last_submit_ms: i64 = 0;
/// Minimum gap between accepted crowd modulations / pedal submissions (global).
pub var mod_cooldown_ms: i64 = 400;
pub var submit_cooldown_ms: i64 = 1000;

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
    if (get and std.mem.eql(u8, path, "/api/melos/pedals")) return handlePedalsList(allocator);
    if (post and std.mem.eql(u8, path, "/api/melos/pedals/submit")) return handlePedalSubmit(allocator, body);
    if (post and std.mem.eql(u8, path, "/api/melos/pedals/approve")) return handlePedalTransition(allocator, body, .approve);
    if (post and std.mem.eql(u8, path, "/api/melos/pedals/activate")) return handlePedalTransition(allocator, body, .activate);
    if (post and std.mem.eql(u8, path, "/api/melos/pedals/reject")) return handlePedalTransition(allocator, body, .reject);
    if (post and std.mem.eql(u8, path, "/api/melos/pedals/deactivate")) return handlePedalTransition(allocator, body, .deactivate);
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

/// Performer routes (live/step, pedal approval) require MELOS_PERFORMER_TOKEN
/// when that environment variable is set. When it is not set they are open to
/// whatever can reach the engine (loopback only; the public proxy whitelists
/// only the viewer routes).
fn performerOk(token: ?[]const u8) bool {
    const want = std.posix.getenv("MELOS_PERFORMER_TOKEN") orelse return true;
    const got = token orelse return false;
    if (got.len != want.len) return false;
    var diff: u8 = 0;
    for (got, want) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

const StepBody = struct {
    base_prompt: ?[]const u8 = null,
    tempo_bpm: ?f32 = null,
    density: ?f32 = null,
    current_tick: ?u64 = null,
    seed: ?u64 = null,
    reset: ?bool = null,
    token: ?[]const u8 = null,
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

fn writeParams(w: anytype, p: generate.Params) !void {
    try w.print("{{\"tempo_bpm\":{d:.1},\"density\":{d:.2},\"energy\":{d:.2},\"syncopation\":{d:.2},\"register\":{d},\"sevenths\":{s}}}", .{
        p.tempo_bpm, p.density, p.energy, p.syncopation, p.register, if (p.seventh) "true" else "false",
    });
}

pub fn handleLiveStep(allocator: std.mem.Allocator, body: []const u8) !Result {
    var scratch: [8 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var sb = StepBody{};
    if (std.mem.trim(u8, body, " \r\n\t").len > 0) {
        sb = std.json.parseFromSliceLeaky(StepBody, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch
            return jsonError(allocator, 400, "invalid json");
    }
    if (!performerOk(sb.token)) return jsonError(allocator, 403, "performer token required");

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

    var merged: [generate.MAX_BAR_NOTES + 28]types.MidiNote = undefined;
    var n: usize = 0;
    @memcpy(merged[n .. n + bo.mel_n], bo.melody[0..bo.mel_n]);
    n += bo.mel_n;
    @memcpy(merged[n .. n + bo.bass_n], bo.bass[0..bo.bass_n]);
    n += bo.bass_n;
    @memcpy(merged[n .. n + bo.pad_n], bo.pad[0..bo.pad_n]);
    n += bo.pad_n;
    const pedals_active = g_pedals.activeCount();
    if (pedals_active > 0) n = g_pedals.applyActive(&merged, n);

    try w.print("{{\"status\":\"ok\",\"bar\":{d},\"tick\":{d},\"next_tick\":{d},\"phrase\":\"{s}\",\"bar_in_phrase\":{d},\"chord\":\"", .{
        state.steps - 1, bar_tick, state.current_tick, bo.phrase.label(), bo.bar_in_phrase,
    });
    try chordName(w, state, bo.chord_deg);
    try w.print("\",\"key\":\"{s} {s}\",\"tempo_bpm\":{d:.1},\"pedals_active\":{d},\"params\":", .{ note_names[state.comp.tonic], @tagName(state.comp.mode), state.comp.p.tempo_bpm, pedals_active });
    try writeParams(w, state.comp.p);
    try w.writeAll(",\"notes\":");
    try writeNotes(w, merged[0..n]);
    try w.writeByte('}');
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
    const prompt = mb.prompt orelse return jsonError(allocator, 400, "missing prompt");

    var out_buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const w = fbs.writer();

    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_live == null) return jsonError(allocator, 409, "no live session: call live/step first");
    const now = std.time.milliTimestamp();
    if (now - g_last_mod_ms < mod_cooldown_ms) {
        return .{ .status = 429, .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"error\":\"slow down\",\"retry_after_ms\":{d}}}", .{mod_cooldown_ms - (now - g_last_mod_ms)}) };
    }
    g_last_mod_ms = now;
    const state = &g_live.?;
    var ap = live.Applied{};
    live.applyPrompt(&state.tgt, prompt, &ap);

    try w.writeAll("{\"status\":\"ok\",\"summary\":");
    var sum_buf: [200]u8 = undefined;
    var sfbs = std.io.fixedBufferStream(&sum_buf);
    const sw = sfbs.writer();
    if (ap.n == 0) {
        try sw.writeAll("no change (try: faster, softer, brighter, darker, busier, groove, higher)");
    } else for (ap.labels[0..ap.n], 0..) |l, i| {
        if (i > 0) try sw.writeAll(", ");
        try sw.writeAll(l);
    }
    try writeJsonString(w, sfbs.getWritten());
    try w.print(",\"applied\":{d},\"targets\":{{\"tempo_bpm\":{d:.1},\"density\":{d:.2},\"energy\":{d:.2},\"syncopation\":{d:.2},\"register\":{d},\"mode\":", .{
        ap.n, state.tgt.tempo, state.tgt.density, state.tgt.energy, state.tgt.syncopation, state.tgt.register,
    });
    if (state.tgt.mode) |m| try w.print("\"{s}\"", .{@tagName(m)}) else try w.writeAll("null");
    try w.writeAll("},\"current\":");
    try writeParams(w, state.comp.p);
    try w.print(",\"tempo_bpm\":{d:.1}}}", .{state.tgt.tempo});
    return .{ .body = try allocator.dupe(u8, fbs.getWritten()) };
}

// ---------------------------------------------------------------------------
// pedals
// ---------------------------------------------------------------------------

fn handlePedalsList(allocator: std.mem.Allocator) !Result {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    g_mutex.lock();
    defer g_mutex.unlock();
    try w.writeAll("{\"pedals\":[");
    for (g_pedals.items[0..g_pedals.count], 0..) |*p, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"id\":{d},\"name\":", .{p.id});
        try writeJsonString(w, p.nameS());
        try w.writeAll(",\"author\":");
        try writeJsonString(w, p.authorS());
        try w.writeAll(",\"target_instrument\":");
        try writeJsonString(w, p.instrumentS());
        try w.writeAll(",\"description\":");
        try writeJsonString(w, p.descriptionS());
        try w.print(",\"status\":\"{s}\",\"pitch_shift\":{d},\"velocity_scale\":{d:.2},\"density_scale\":{d:.2},\"reverb_amount\":{d:.2},\"delay_ticks\":{d}}}", .{
            @tagName(p.status), p.pitch_shift, p.velocity_scale, p.density_scale, p.reverb_amount, p.delay_ticks,
        });
    }
    try w.writeAll("]}");
    return .{ .body = try buf.toOwnedSlice() };
}

const PedalBody = struct {
    name: ?[]const u8 = null,
    author: ?[]const u8 = null,
    target_instrument: ?[]const u8 = null,
    instrument: ?[]const u8 = null,
    description: ?[]const u8 = null,
    pitch_shift: ?f32 = null,
    velocity_scale: ?f32 = null,
    density_scale: ?f32 = null,
    reverb_amount: ?f32 = null,
    delay_ticks: ?f32 = null,
};

fn handlePedalSubmit(allocator: std.mem.Allocator, body: []const u8) !Result {
    var scratch: [4 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const pb = std.json.parseFromSliceLeaky(PedalBody, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch
        return jsonError(allocator, 400, "invalid json");
    g_mutex.lock();
    defer g_mutex.unlock();
    const now = std.time.milliTimestamp();
    if (now - g_last_submit_ms < submit_cooldown_ms) return jsonError(allocator, 429, "slow down");
    const id = g_pedals.submit(.{
        .name = pb.name orelse "",
        .author = pb.author orelse "crowd",
        .instrument = pb.target_instrument orelse pb.instrument orelse "",
        .description = pb.description orelse "",
        .pitch_shift = @intFromFloat(std.math.clamp(pb.pitch_shift orelse 0, -12, 12)),
        .velocity_scale = pb.velocity_scale orelse 1.0,
        .density_scale = pb.density_scale orelse 1.0,
        .reverb_amount = pb.reverb_amount orelse 0.0,
        .delay_ticks = @intFromFloat(std.math.clamp(pb.delay_ticks orelse 0, 0, 960)),
    }) catch |e| return switch (e) {
        error.BadName => jsonError(allocator, 400, "pedal needs a name"),
        error.UnknownInstrument => jsonError(allocator, 400, "unknown instrument"),
        error.BoardFull => jsonError(allocator, 409, "pedal board is full"),
    };
    g_last_submit_ms = now;
    return .{ .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"submitted\",\"id\":{d}}}", .{id}) };
}

const TransBody = struct { id: ?u32 = null, token: ?[]const u8 = null };

fn handlePedalTransition(allocator: std.mem.Allocator, body: []const u8, t: pedals.PedalBoard.Transition) !Result {
    var scratch: [2 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const tb = std.json.parseFromSliceLeaky(TransBody, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch
        return jsonError(allocator, 400, "invalid json");
    if (!performerOk(tb.token)) return jsonError(allocator, 403, "performer token required");
    const id = tb.id orelse return jsonError(allocator, 400, "missing id");
    g_mutex.lock();
    defer g_mutex.unlock();
    if (!g_pedals.transition(id, t)) return jsonError(allocator, 409, "pedal not found or transition not allowed");
    const p = g_pedals.find(id).?;
    return .{ .body = try std.fmt.allocPrint(allocator, "{{\"status\":\"ok\",\"id\":{d},\"pedal_status\":\"{s}\"}}", .{ id, @tagName(p.status) }) };
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
    try testing.expect(std.mem.indexOf(u8, m.body, "mode minor") != null);
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

fn firstNotePitch(body: []const u8) !i64 {
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer p.deinit();
    return p.value.object.get("notes").?.array.items[0].object.get("pitch").?.integer;
}

test "modulate returns real values and tempo actually moves over following steps" {
    mod_cooldown_ms = 0;
    submit_cooldown_ms = 0;
    defer {
        mod_cooldown_ms = 400;
        submit_cooldown_ms = 1000;
    }
    const s0 = try handle(testing.allocator, .post, "/api/melos/live/step", "{\"seed\":4,\"reset\":true,\"tempo_bpm\":100,\"density\":0.5}");
    testing.allocator.free(s0.body);
    const m = try handle(testing.allocator, .post, "/api/melos/live/modulate", "{\"prompt\":\"Much FASTER please\"}");
    defer testing.allocator.free(m.body);
    try testing.expectEqual(@as(u16, 200), m.status);
    const pm = try std.json.parseFromSlice(std.json.Value, testing.allocator, m.body, .{});
    defer pm.deinit();
    const tgt = pm.value.object.get("targets").?.object.get("tempo_bpm").?.float;
    try testing.expect(tgt >= 119.9);
    try testing.expect(pm.value.object.get("current") != null);
    var last: f64 = 0;
    for (0..4) |_| {
        const r = try handle(testing.allocator, .post, "/api/melos/live/step", "{}");
        defer testing.allocator.free(r.body);
        const p = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.body, .{});
        defer p.deinit();
        last = p.value.object.get("tempo_bpm").?.float;
    }
    try testing.expect(last > 100.0 and last <= 120.0);
    const bad = try handle(testing.allocator, .post, "/api/melos/live/modulate", "{oops");
    defer testing.allocator.free(bad.body);
    try testing.expectEqual(@as(u16, 400), bad.status);
    const nop = try handle(testing.allocator, .post, "/api/melos/live/modulate", "{}");
    defer testing.allocator.free(nop.body);
    try testing.expectEqual(@as(u16, 400), nop.status);
}

test "modulation is rate limited with a JSON 429" {
    mod_cooldown_ms = 60_000;
    defer mod_cooldown_ms = 400;
    g_last_mod_ms = 0;
    const s0 = try handle(testing.allocator, .post, "/api/melos/live/step", "{\"seed\":4,\"reset\":true}");
    testing.allocator.free(s0.body);
    const a = try handle(testing.allocator, .post, "/api/melos/live/modulate", "{\"prompt\":\"fast\"}");
    testing.allocator.free(a.body);
    try testing.expectEqual(@as(u16, 200), a.status);
    const b = try handle(testing.allocator, .post, "/api/melos/live/modulate", "{\"prompt\":\"fast\"}");
    defer testing.allocator.free(b.body);
    try testing.expectEqual(@as(u16, 429), b.status);
    try testing.expect(std.mem.indexOf(u8, b.body, "retry_after_ms") != null);
}

test "pedals: submit, list, performer approval, applied to live notes" {
    mod_cooldown_ms = 0;
    submit_cooldown_ms = 0;
    defer {
        mod_cooldown_ms = 400;
        submit_cooldown_ms = 1000;
    }
    g_mutex.lock();
    g_pedals = .{};
    g_mutex.unlock();
    const base0 = try handle(testing.allocator, .post, "/api/melos/live/step", "{\"seed\":8,\"reset\":true}");
    defer testing.allocator.free(base0.body);
    const base_pitch = try firstNotePitch(base0.body);

    const bad = try handle(testing.allocator, .post, "/api/melos/pedals/submit", "{\"name\":\"x\",\"target_instrument\":\"Kazoo\"}");
    defer testing.allocator.free(bad.body);
    try testing.expectEqual(@as(u16, 400), bad.status);
    const sub = try handle(testing.allocator, .post, "/api/melos/pedals/submit", "{\"name\":\"Up \\\"5\\\"\",\"author\":\"crowd\",\"target_instrument\":\"Piano\",\"description\":\"d\",\"pitch_shift\":5,\"velocity_scale\":1,\"reverb_amount\":0.2,\"delay_ticks\":0}");
    defer testing.allocator.free(sub.body);
    try testing.expectEqual(@as(u16, 200), sub.status);
    const list = try handle(testing.allocator, .get, "/api/melos/pedals", "");
    defer testing.allocator.free(list.body);
    const lp = try std.json.parseFromSlice(std.json.Value, testing.allocator, list.body, .{});
    defer lp.deinit();
    const p0 = lp.value.object.get("pedals").?.array.items[0].object;
    try testing.expectEqualStrings("submitted", p0.get("status").?.string);
    try testing.expectEqualStrings("Up \"5\"", p0.get("name").?.string);

    // not approved -> cannot activate; approved+active -> notes shift by 5
    const na = try handle(testing.allocator, .post, "/api/melos/pedals/activate", "{\"id\":1}");
    defer testing.allocator.free(na.body);
    try testing.expectEqual(@as(u16, 409), na.status);
    const ap = try handle(testing.allocator, .post, "/api/melos/pedals/approve", "{\"id\":1}");
    defer testing.allocator.free(ap.body);
    try testing.expectEqual(@as(u16, 200), ap.status);
    const ac = try handle(testing.allocator, .post, "/api/melos/pedals/activate", "{\"id\":1}");
    defer testing.allocator.free(ac.body);
    try testing.expectEqual(@as(u16, 200), ac.status);
    const again = try handle(testing.allocator, .post, "/api/melos/live/step", "{\"seed\":8,\"reset\":true}");
    defer testing.allocator.free(again.body);
    try testing.expect(std.mem.indexOf(u8, again.body, "\"pedals_active\":1") != null);
    try testing.expectEqual(base_pitch + 5, try firstNotePitch(again.body));
}
