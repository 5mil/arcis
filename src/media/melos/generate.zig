//! Melos text/attribute -> symbolic generation.
//!
//! A `Composer` produces one bar at a time (melody + bass + pad) from a
//! deterministic per-bar PRNG, so the same engine drives both one-shot piece
//! generation and the live performance loop. Everything is allocation-free
//! per bar: callers pass a stack `BarOut`.
//!
//! Musical model: key/mode (from attributes, emotion or seed) -> 16-bar period
//! of four phrases (A, A', B, cadence) over per-mode chord progressions;
//! melody = contour-guided scale walk that lands on chord tones on strong
//! beats; bass = root/fifth patterns with anticipations; pad = voice-led
//! triads/sevenths without parallel fifths or octaves; seeded humanization.

const std = @import("std");
const types = @import("types.zig");
const theory = @import("theory.zig");

pub const TICKS_PER_BAR: u32 = 1920;
pub const SIXTEENTH: u32 = 120;
pub const MAX_MEL = 16;
pub const MAX_BASS = 8;
pub const MAX_PAD = 4;
pub const MAX_BAR_NOTES = MAX_MEL + MAX_BASS + MAX_PAD;
pub const MAX_GEN_BARS: u16 = 32;

pub const Phrase = enum {
    A,
    A2,
    B,
    cadence,

    pub fn label(self: Phrase) []const u8 {
        return switch (self) {
            .A => "A",
            .A2 => "A'",
            .B => "B",
            .cadence => "cadence",
        };
    }
};

/// Generation request.
pub const GenerateRequest = struct {
    text: ?[]const u8 = null,
    attributes: ?types.MusicAttributes = null,
    mask: ?types.TrackMask = null,
    bars: u16 = 8,
    seed: u64 = 42,
    syncopation: ?f32 = null,
    humanize: ?f32 = null,
};

/// Generation result.
pub const GenerateResult = struct {
    piece: types.SymbolicPiece,
    /// Optional trace from the planner / model.
    trace: ?[]const u8 = null,

    pub fn deinit(self: *GenerateResult) void {
        self.piece.deinit();
    }
};

/// Continuous performance parameters (live modulation moves these smoothly).
pub const Params = struct {
    tempo_bpm: f32 = 100,
    density: f32 = 0.5, // rhythmic activity 0..1
    energy: f32 = 0.5, // dynamics 0..1
    syncopation: f32 = 0.2, // 0..1
    humanize: f32 = 0.5, // 0..1
    register: i8 = 0, // shift of the melodic window in scale steps
    seventh: bool = false, // add 7ths to the pad

    pub fn clamp(self: *Params) void {
        self.tempo_bpm = std.math.clamp(self.tempo_bpm, 40, 220);
        self.density = std.math.clamp(self.density, 0.05, 1.0);
        self.energy = std.math.clamp(self.energy, 0.05, 1.0);
        self.syncopation = std.math.clamp(self.syncopation, 0, 1);
        self.humanize = std.math.clamp(self.humanize, 0, 1);
        self.register = std.math.clamp(self.register, -7, 7);
    }
};

pub const BarOut = struct {
    melody: [MAX_MEL]types.MidiNote = undefined,
    mel_n: usize = 0,
    bass: [MAX_BASS]types.MidiNote = undefined,
    bass_n: usize = 0,
    pad: [MAX_PAD]types.MidiNote = undefined,
    pad_n: usize = 0,
    chord_deg: u8 = 0,
    phrase: Phrase = .A,
    bar_in_phrase: u8 = 0,
    is_final: bool = false,

    pub fn total(self: *const BarOut) usize {
        return self.mel_n + self.bass_n + self.pad_n;
    }
};

const Cell = struct {
    n: u8 = 0,
    pos: [16]u8 = undefined,
    dur: [16]u8 = undefined,
    rest: [16]bool = undefined,
    step: [16]i16 = undefined,
};

pub const Composer = struct {
    tonic: u4,
    mode: types.Mode,
    tonic_mid: i32,
    emotion: types.Emotion,
    p: Params,
    seed: u64,
    bar_index: u32 = 0,
    finite_bars: ?u32 = null,
    pitch_low: u8 = 58,
    pitch_high: u8 = 83,
    // carried state
    cur_step: i32 = 4,
    leap_dir: i8 = 0,
    voicing: ?theory.Voicing = null,

    pub fn init(req: GenerateRequest) Composer {
        const attrs = req.attributes orelse types.MusicAttributes{};
        const emo: types.Emotion = attrs.emotion orelse
            (if (req.text) |t| emotionFromText(t) else null) orelse
            (if (attrs.key) |k| emotionForMode(k.mode) else theory.defaultEmotion(req.seed));
        const prof = theory.emotionProfile(emo);
        const key = attrs.key orelse types.Key{ .tonic = theory.defaultTonic(req.seed), .mode = prof.mode };
        var p = Params{
            .tempo_bpm = attrs.tempo_bpm orelse prof.tempo,
            .density = attrs.density orelse prof.density,
            .energy = prof.energy,
            .syncopation = req.syncopation orelse prof.syncopation,
            .humanize = req.humanize orelse 0.5,
            .seventh = prof.seventh,
        };
        p.clamp();
        var c = Composer{
            .tonic = key.tonic,
            .mode = key.mode,
            .tonic_mid = theory.tonicMidi(key.tonic),
            .emotion = emo,
            .p = p,
            .seed = req.seed,
        };
        if (attrs.pitch_range) |r| {
            c.pitch_low = r.low;
            c.pitch_high = @max(r.high, r.low + 12);
        }
        c.cur_step = c.stepNear(c.tonic_mid + 7);
        return c;
    }

    /// Re-key at a bar boundary (live modulation). Keeps register by re-snapping.
    pub fn setKey(self: *Composer, tonic: u4, mode: types.Mode) void {
        self.tonic = tonic;
        self.mode = mode;
        self.tonic_mid = theory.tonicMidi(tonic);
        self.cur_step = self.stepNear(@intFromFloat(@as(f32, @floatFromInt(self.pitchLow() + self.pitchHigh())) * 0.5));
        self.leap_dir = 0;
    }

    fn stepNear(self: *const Composer, midi: i32) i32 {
        var best: i32 = 0;
        var bd: i32 = std.math.maxInt(i32);
        var s: i32 = -21;
        while (s <= 35) : (s += 1) {
            const d: i32 = @intCast(@abs(theory.stepOffset(self.mode, s) + self.tonic_mid - midi));
            if (d < bd) {
                bd = d;
                best = s;
            }
        }
        return best;
    }

    fn pitchLow(self: *const Composer) i32 {
        return @as(i32, self.pitch_low) + @as(i32, self.p.register) * 2;
    }
    fn pitchHigh(self: *const Composer) i32 {
        return @as(i32, self.pitch_high) + @as(i32, self.p.register) * 2;
    }

    /// Inclusive melodic step window for the current key/register.
    fn window(self: *const Composer) struct { lo: i32, hi: i32 } {
        var lo: i32 = 35;
        var hi: i32 = -21;
        const pl = self.pitchLow();
        const ph = self.pitchHigh();
        var s: i32 = -21;
        while (s <= 35) : (s += 1) {
            const pm = self.tonic_mid + theory.stepOffset(self.mode, s);
            if (pm >= pl and pm <= ph) {
                if (s < lo) lo = s;
                if (s > hi) hi = s;
            }
        }
        if (hi - lo < 7) {
            const c = self.stepNear(@divTrunc(pl + ph, 2));
            lo = c - 4;
            hi = c + 4;
        }
        return .{ .lo = lo, .hi = hi };
    }

    // ----- harmony -------------------------------------------------------

    fn progIndex(self: *const Composer, period: u32) usize {
        return @intCast(theory.mix(self.seed, 0xA000 + period) % 4);
    }

    /// Chord (scale degree) sounding in bar `b`.
    pub fn chordDegAt(self: *const Composer, b: u32) u8 {
        const bip = b % 16;
        const ph = bip / 4;
        const bi = bip % 4;
        const m = @intFromEnum(self.mode);
        var deg: u8 = switch (ph) {
            0, 1 => theory.progs[m][self.progIndex(b / 16)][bi],
            2 => theory.progs[m][(self.progIndex(b / 16) + 1) % 4][bi],
            else => theory.cadences[m][bi],
        };
        if (self.finite_bars) |n| {
            if (b + 1 == n) deg = 0;
            if (n >= 2 and b + 2 == n) deg = theory.cadences[m][2];
        }
        return deg;
    }

    fn isFinalBar(self: *const Composer, b: u32) bool {
        if (self.finite_bars) |n| if (b + 1 == n) return true;
        return b % 16 == 15;
    }
    fn isPenultimate(self: *const Composer, b: u32) bool {
        if (self.finite_bars) |n| if (n >= 2 and b + 2 == n) return true;
        return b % 16 == 14;
    }

    // ----- one bar -------------------------------------------------------

    pub fn nextBar(self: *Composer, out: *BarOut) void {
        const b = self.bar_index;
        self.bar_index += 1;
        var rng = std.Random.DefaultPrng.init(theory.mix(self.seed, b));
        const rnd = rng.random();

        const bip = b % 16;
        out.* = .{};
        out.phrase = @enumFromInt(bip / 4);
        out.bar_in_phrase = @intCast(bip % 4);
        out.is_final = self.isFinalBar(b);
        const deg: i32 = self.chordDegAt(b);
        out.chord_deg = @intCast(deg);
        const bar_start: i32 = @intCast(b * TICKS_PER_BAR);
        const win = self.window();

        self.melodyBar(out, rnd, bar_start, deg, win.lo, win.hi, self.isPenultimate(b));
        self.bassBar(out, rnd, bar_start, deg, self.chordDegAt(b + 1), out.is_final);
        self.padBar(out, rnd, bar_start, deg);
    }

    fn jitter(self: *const Composer, rnd: std.Random, amount: i32) i32 {
        const j: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(amount)) * self.p.humanize));
        if (j <= 0) return 0;
        return rnd.intRangeAtMost(i32, -j, j);
    }

    fn clampVel(v: i32) u8 {
        return @intCast(std.math.clamp(v, 20, 122));
    }

    fn startTick(bar_start: i32, pos: i32, jit: i32) u32 {
        return @intCast(@max(bar_start + pos * @as(i32, SIXTEENTH) + jit, 0));
    }

    // ----- melody --------------------------------------------------------

    fn genRhythm(self: *const Composer, rnd: std.Random, cell: *Cell) void {
        const d = self.p.density;
        const sync = self.p.syncopation;
        var pos: u8 = 0;
        cell.n = 0;
        while (pos < 16 and cell.n < 16) {
            const rem: u8 = 16 - pos;
            var w = [6]f32{
                d * d * 3.0,
                1.5 + d * 3.5,
                if (pos % 4 == 0) sync * 3.0 else 0,
                3.2 - d * 2.0,
                if (pos % 4 == 0) (0.6 + sync * 1.5) * (1.1 - d) else 0,
                if (pos % 8 == 0) (1.0 - d) * 2.5 else 0,
            };
            const durs = [6]u8{ 1, 2, 3, 4, 6, 8 };
            if (pos % 2 == 1) {
                w[2] = 0;
                w[3] = 0;
                w[4] = 0;
                w[5] = 0;
            }
            var total: f32 = 0;
            for (&w, durs) |*x, dv| {
                if (dv > rem) x.* = 0;
                total += x.*;
            }
            var dur: u8 = 1;
            if (total > 0) {
                var r = rnd.float(f32) * total;
                for (w, durs) |x, dv| {
                    if (x <= 0) continue;
                    if (r < x) {
                        dur = dv;
                        break;
                    }
                    r -= x;
                    dur = dv;
                }
            }
            const strong = pos % 8 == 0;
            const prev_rest = cell.n > 0 and cell.rest[cell.n - 1];
            const rest = !strong and pos > 0 and !prev_rest and rnd.float(f32) < (1.0 - d) * 0.20;
            cell.pos[cell.n] = pos;
            cell.dur[cell.n] = dur;
            cell.rest[cell.n] = rest;
            cell.n += 1;
            pos += dur;
        }
    }

    fn fitChord(step_in: i32, deg: i32, lo: i32, hi: i32) i32 {
        var s = theory.snapToChord(step_in, deg);
        while (s > hi) s -= 1;
        while (s < lo) s += 1;
        // After clamping, walk to the nearest chord tone inside the window.
        var k: i32 = 0;
        while (k < 7) : (k += 1) {
            if (s - k >= lo and theory.isChordStep(s - k, deg)) return s - k;
            if (s + k <= hi and theory.isChordStep(s + k, deg)) return s + k;
        }
        return s;
    }

    fn walk(self: *Composer, rnd: std.Random, strong: bool, deg: i32, target: i32, lo: i32, hi: i32) i32 {
        var s = self.cur_step;
        if (self.leap_dir != 0) {
            s -= self.leap_dir; // resolve a leap by step in the opposite direction
            self.leap_dir = 0;
        } else {
            var dir: i32 = std.math.sign(target - s);
            if (dir == 0) dir = if (rnd.boolean()) 1 else -1;
            if (rnd.float(f32) >= 0.65) dir = -dir;
            const r = rnd.float(f32);
            if (r < 0.12) {
                // repeat
            } else if (r < 0.62) {
                s += dir;
            } else if (r < 0.80) {
                s += 2 * dir;
            } else if (r < 0.92) {
                s += (3 + @as(i32, @intCast(rnd.uintLessThan(u8, 2)))) * dir;
                self.leap_dir = @intCast(dir);
            } else {
                s -= dir;
            }
        }
        if (s > hi) {
            s = hi - (s - hi);
            self.leap_dir = 0;
        }
        if (s < lo) {
            s = lo + (lo - s);
            self.leap_dir = 0;
        }
        s = std.math.clamp(s, lo, hi);
        if (strong) s = fitChord(s, deg, lo, hi);
        return s;
    }

    fn nearestStepWithDegrees(self: *const Composer, near: i32, d1: i32, d2: i32, lo: i32, hi: i32) ?i32 {
        _ = self;
        var k: i32 = 0;
        while (k <= 6) : (k += 1) {
            for ([2]i32{ near - k, near + k }) |s| {
                if (s < lo or s > hi) continue;
                const m = @mod(s, 7);
                if (m == d1 or m == d2) return s;
            }
        }
        return null;
    }

    fn melodyBar(self: *Composer, out: *BarOut, rnd: std.Random, bar_start: i32, deg: i32, lo: i32, hi: i32, penult: bool) void {
        const bip: u8 = out.bar_in_phrase;
        const vbase: i32 = 52 + @as(i32, @intFromFloat(self.p.energy * 36.0));
        const swell = [4]i32{ 0, 3, 6, 2 };

        if (out.is_final) {
            const s = self.nearestStepWithDegrees(self.cur_step, 0, 0, lo, hi) orelse self.cur_step;
            self.cur_step = s;
            self.leap_dir = 0;
            out.melody[0] = .{
                .pitch = theory.pitchOf(self.tonic_mid, self.mode, s),
                .velocity = clampVel(vbase + 10 + self.jitter(rnd, 6)),
                .start_tick = startTick(bar_start, 0, 0),
                .duration_ticks = TICKS_PER_BAR,
                .channel = 0,
            };
            out.mel_n = 1;
            return;
        }

        var cell = Cell{};
        self.genRhythm(rnd, &cell);

        // Contour target (scale steps relative to the tonic octave): an arch.
        const arch = [4]i32{ 4, 6, 5, 2 };
        const target = arch[bip] + @as(i32, self.p.register);

        var last_sounding: ?usize = null;
        for (0..cell.n) |i| {
            if (cell.rest[i]) continue;
            const strong = cell.pos[i] % 8 == 0;
            cell.step[i] = @intCast(self.walk(rnd, strong, deg, target, lo, hi));
            self.cur_step = cell.step[i];
            last_sounding = i;
        }
        if (penult) if (last_sounding) |li| {
            const strong = cell.pos[li] % 8 == 0;
            if (self.nearestStepWithDegrees(cell.step[li], 1, 6, lo, hi)) |c| {
                if (!strong or theory.isChordStep(c, deg)) {
                    cell.step[li] = @intCast(c);
                    self.cur_step = c;
                    self.leap_dir = 0;
                }
            }
        };

        self.emitMelody(out, rnd, &cell, bar_start, vbase + swell[bip]);
    }

    fn emitMelody(self: *const Composer, out: *BarOut, rnd: std.Random, cell: *const Cell, bar_start: i32, vb: i32) void {
        var n: usize = 0;
        for (0..cell.n) |i| {
            if (cell.rest[i]) continue;
            const pos: i32 = cell.pos[i];
            const accent: i32 = if (pos == 0) 10 else if (@mod(pos, 8) == 0) 5 else if (@mod(pos, 2) == 1) -7 else 0;
            out.melody[n] = .{
                .pitch = theory.pitchOf(self.tonic_mid, self.mode, cell.step[i]),
                .velocity = clampVel(vb + accent + self.jitter(rnd, 6)),
                .start_tick = startTick(bar_start, pos, self.jitter(rnd, 8)),
                .duration_ticks = @as(u32, cell.dur[i]) * SIXTEENTH,
                .channel = 0,
            };
            n += 1;
        }
        out.mel_n = n;
    }

    // ----- bass ----------------------------------------------------------

    fn bassRoot(self: *const Composer, deg: i32) u8 {
        const pc: i32 = theory.stepPc(self.tonic, self.mode, deg);
        return @intCast(36 + @mod(pc - 36, 12));
    }

    fn bassFifth(self: *const Composer, deg: i32, root: u8) u8 {
        const pc5: i32 = theory.stepPc(self.tonic, self.mode, deg + 4);
        return root + @as(u8, @intCast(@mod(pc5 - @as(i32, root), 12)));
    }

    fn putBass(out: *BarOut, rnd: std.Random, self: *const Composer, bar_start: i32, pos: i32, dur: i32, pitch: u8, vel: i32) void {
        if (out.bass_n >= MAX_BASS) return;
        out.bass[out.bass_n] = .{
            .pitch = pitch,
            .velocity = clampVel(vel + self.jitter(rnd, 5)),
            .start_tick = startTick(bar_start, pos, self.jitter(rnd, 6)),
            .duration_ticks = @intCast(dur * @as(i32, SIXTEENTH)),
            .channel = 2,
        };
        out.bass_n += 1;
    }

    fn bassBar(self: *const Composer, out: *BarOut, rnd: std.Random, bar_start: i32, deg: i32, next_deg: u8, final: bool) void {
        const root = self.bassRoot(deg);
        const fifth = self.bassFifth(deg, root);
        const vb: i32 = 62 + @as(i32, @intFromFloat(self.p.energy * 26.0));
        const d = self.p.density;
        if (final) {
            putBass(out, rnd, self, bar_start, 0, 16, root, vb + 6);
            return;
        }
        const nroot = self.bassRoot(next_deg);
        if (d < 0.35) {
            putBass(out, rnd, self, bar_start, 0, 8, root, vb + 8);
            putBass(out, rnd, self, bar_start, 8, 8, if (rnd.boolean()) fifth else root, vb);
        } else if (d < 0.7) {
            putBass(out, rnd, self, bar_start, 0, 4, root, vb + 8);
            putBass(out, rnd, self, bar_start, 4, 4, fifth, vb - 4);
            putBass(out, rnd, self, bar_start, 8, 4, root, vb + 2);
            if (rnd.float(f32) < self.p.syncopation and next_deg != deg) {
                // anticipate the next chord on the "and" of 4
                putBass(out, rnd, self, bar_start, 12, 2, fifth, vb - 4);
                putBass(out, rnd, self, bar_start, 14, 2, nroot, vb + 2);
            } else {
                putBass(out, rnd, self, bar_start, 12, 4, fifth, vb - 4);
            }
        } else {
            const approach_off: i32 = theory.stepOffset(self.mode, next_deg) - theory.stepOffset(self.mode, @as(i32, next_deg) - 1);
            var approach: i32 = @as(i32, nroot) - approach_off;
            if (approach < 33) approach += 12;
            const pat = [8]u8{ root, root, fifth, root, root, root, fifth, @intCast(approach) };
            for (pat, 0..) |pt, i| {
                const strong = i % 4 == 0;
                putBass(out, rnd, self, bar_start, @intCast(i * 2), 2, pt, vb + (if (strong) @as(i32, 8) else -2));
            }
        }
    }

    // ----- pad -----------------------------------------------------------

    fn padBar(self: *Composer, out: *BarOut, rnd: std.Random, bar_start: i32, deg: i32) void {
        const n: u8 = if (self.p.seventh) 4 else 3;
        var pcs: [4]u8 = .{ 0, 0, 0, 0 };
        for (0..n) |i| pcs[i] = theory.stepPc(self.tonic, self.mode, deg + 2 * @as(i32, @intCast(i)));
        const v = theory.voiceLead(self.voicing, pcs, n, 52);
        self.voicing = v;
        const vb: i32 = 44 + @as(i32, @intFromFloat(self.p.energy * 24.0));
        for (0..n) |i| {
            out.pad[i] = .{
                .pitch = v.p[i],
                .velocity = clampVel(vb + self.jitter(rnd, 4)),
                .start_tick = @intCast(@max(bar_start, 0)),
                .duration_ticks = TICKS_PER_BAR,
                .channel = 1,
            };
        }
        out.pad_n = n;
    }
};

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

pub fn emotionForMode(m: types.Mode) types.Emotion {
    return switch (m) {
        .major => .happy,
        .minor => .sad,
        .dorian => .calm,
        .mixolydian => .relaxed,
        .lydian => .bright,
        .phrygian => .tense,
    };
}

/// First emotion keyword found in `text` (case-insensitive), if any.
pub fn emotionFromText(text: []const u8) ?types.Emotion {
    var buf: [256]u8 = undefined;
    const n = @min(text.len, buf.len);
    for (text[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const s = buf[0..n];
    const table = [_]struct { k: []const u8, e: types.Emotion }{
        .{ .k = "energ", .e = .energetic },
        .{ .k = "hype", .e = .energetic },
        .{ .k = "happy", .e = .happy },
        .{ .k = "joy", .e = .happy },
        .{ .k = "sad", .e = .sad },
        .{ .k = "melanchol", .e = .sad },
        .{ .k = "calm", .e = .calm },
        .{ .k = "chill", .e = .calm },
        .{ .k = "dark", .e = .dark },
        .{ .k = "bright", .e = .bright },
        .{ .k = "tense", .e = .tense },
        .{ .k = "relax", .e = .relaxed },
    };
    for (table) |t| if (std.mem.indexOf(u8, s, t.k) != null) return t.e;
    return null;
}

pub fn programFor(role: types.TrackRole) u8 {
    return switch (role) {
        .melody => 0, // piano
        .pad => 48, // strings
        .bass => 33, // finger bass
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// One-shot piece generation
// ---------------------------------------------------------------------------

/// Generate a multi-track piece (melody, pad, bass). `tracks[0]` is the melody.
pub fn generateStub(allocator: std.mem.Allocator, req: GenerateRequest) !GenerateResult {
    var attrs = req.attributes orelse types.MusicAttributes{};
    const bars: u16 = std.math.clamp(attrs.bars orelse req.bars, 1, MAX_GEN_BARS);
    attrs.bars = bars;

    var comp = Composer.init(req);
    comp.finite_bars = bars;

    var mel = try std.ArrayList(types.MidiNote).initCapacity(allocator, @as(usize, bars) * MAX_MEL);
    errdefer mel.deinit();
    var pad = try std.ArrayList(types.MidiNote).initCapacity(allocator, @as(usize, bars) * MAX_PAD);
    errdefer pad.deinit();
    var bass = try std.ArrayList(types.MidiNote).initCapacity(allocator, @as(usize, bars) * MAX_BASS);
    errdefer bass.deinit();

    var bo = BarOut{};
    var b: u16 = 0;
    while (b < bars) : (b += 1) {
        comp.nextBar(&bo);
        mel.appendSliceAssumeCapacity(bo.melody[0..bo.mel_n]);
        pad.appendSliceAssumeCapacity(bo.pad[0..bo.pad_n]);
        bass.appendSliceAssumeCapacity(bo.bass[0..bo.bass_n]);
    }

    attrs.key = .{ .tonic = comp.tonic, .mode = comp.mode };
    attrs.tempo_bpm = comp.p.tempo_bpm;
    attrs.emotion = comp.emotion;
    attrs.density = comp.p.density;
    if (attrs.time_signature == null) attrs.time_signature = .{ .numerator = 4, .denominator = 4 };

    const tracks = try allocator.alloc(types.MidiTrack, 3);
    errdefer allocator.free(tracks);
    const names = [3][]const u8{ "melody", "pad", "bass" };
    const roles = [3]types.TrackRole{ .melody, .pad, .bass };
    var made: usize = 0;
    errdefer for (tracks[0..made]) |*t| t.deinit();
    const lists = [3]*std.ArrayList(types.MidiNote){ &mel, &pad, &bass };
    for (0..3) |i| {
        const name = try allocator.dupe(u8, names[i]);
        errdefer allocator.free(name);
        tracks[i] = .{
            .name = name,
            .role = roles[i],
            .program = programFor(roles[i]),
            .events = try lists[i].toOwnedSlice(),
            .allocator = allocator,
        };
        made += 1;
    }

    return GenerateResult{
        .piece = .{
            .attributes = attrs,
            .tracks = tracks,
            .ticks_per_quarter = 480,
            .allocator = allocator,
        },
        .trace = null,
    };
}

// ---------------------------------------------------------------------------
// Tests (stage 2: scales, harmony, voice leading, emotion -> mode, defaults)
// ---------------------------------------------------------------------------

const testing = std.testing;
const metrics = @import("metrics.zig");

fn gridPosOf(t: u32) u32 {
    return ((t % TICKS_PER_BAR) + 60) / SIXTEENTH;
}

test "generated notes are 100% in key across emotions and seeds" {
    const emos = [_]types.Emotion{ .happy, .sad, .energetic, .calm, .dark, .bright, .tense, .relaxed };
    for (emos) |e| {
        var seed: u64 = 1;
        while (seed <= 12) : (seed += 1) {
            var r = try generateStub(testing.allocator, .{
                .bars = 16,
                .seed = seed,
                .attributes = .{ .emotion = e },
            });
            defer r.deinit();
            const k = r.piece.attributes.key.?;
            for (r.piece.tracks) |t| for (t.events) |nt|
                try testing.expect(metrics.inKey(nt.pitch, k.tonic, k.mode));
        }
    }
}

test "strong beats carry chord tones (melody beats 1 and 3)" {
    for (0..6) |mi| {
        var seed: u64 = 100;
        while (seed < 110) : (seed += 1) {
            var c = Composer.init(.{ .seed = seed, .attributes = .{ .key = .{ .tonic = 2, .mode = @enumFromInt(mi) } } });
            var bo = BarOut{};
            for (0..48) |_| {
                c.nextBar(&bo);
                for (bo.melody[0..bo.mel_n]) |nt| {
                    if (gridPosOf(nt.start_tick) % 8 != 0) continue;
                    const deg: i32 = bo.chord_deg;
                    const pcs = [3]u8{ theory.stepPc(c.tonic, c.mode, deg), theory.stepPc(c.tonic, c.mode, deg + 2), theory.stepPc(c.tonic, c.mode, deg + 4) };
                    const pc: u8 = nt.pitch % 12;
                    try testing.expect(pc == pcs[0] or pc == pcs[1] or pc == pcs[2]);
                }
            }
        }
    }
}

test "pad voice leading has no parallel fifths/octaves in generated pieces" {
    for (0..6) |mi| {
        var seed: u64 = 7;
        while (seed < 13) : (seed += 1) {
            var r = try generateStub(testing.allocator, .{ .bars = 32, .seed = seed, .attributes = .{ .key = .{ .tonic = 5, .mode = @enumFromInt(mi) } } });
            defer r.deinit();
            const pad = r.piece.tracks[1].events;
            var prev: ?theory.Voicing = null;
            var i: usize = 0;
            while (i < pad.len) {
                var v = theory.Voicing{};
                const t0 = pad[i].start_tick;
                while (i < pad.len and pad[i].start_tick == t0) : (i += 1) {
                    v.p[v.n] = pad[i].pitch;
                    v.n += 1;
                }
                if (prev) |pv| try testing.expectEqual(@as(u32, 0), theory.parallels(pv, v));
                prev = v;
            }
        }
    }
}

test "registers and ranges are respected" {
    var seed: u64 = 1;
    while (seed < 30) : (seed += 1) {
        var r = try generateStub(testing.allocator, .{ .bars = 24, .seed = seed });
        defer r.deinit();
        for (r.piece.tracks[0].events) |nt| try testing.expect(nt.pitch >= 55 and nt.pitch <= 86);
        for (r.piece.tracks[1].events) |nt| try testing.expect(nt.pitch >= 52 and nt.pitch <= 76);
        for (r.piece.tracks[2].events) |nt| try testing.expect(nt.pitch >= 33 and nt.pitch <= 56);
        for (r.piece.tracks) |t| for (t.events) |nt| try testing.expect(nt.velocity >= 20 and nt.velocity <= 122);
    }
    // explicit pitch range
    var r = try generateStub(testing.allocator, .{ .bars = 16, .seed = 3, .attributes = .{ .pitch_range = .{ .low = 64, .high = 76 } } });
    defer r.deinit();
    for (r.piece.tracks[0].events) |nt| try testing.expect(nt.pitch >= 64 - 2 and nt.pitch <= 76 + 2);
}

test "emotion maps to mode and key defaults apply" {
    var r = try generateStub(testing.allocator, .{ .seed = 5, .attributes = .{ .emotion = .sad } });
    defer r.deinit();
    try testing.expectEqual(types.Mode.minor, r.piece.attributes.key.?.mode);
    try testing.expectEqual(types.Emotion.sad, r.piece.attributes.emotion.?);
    var r2 = try generateStub(testing.allocator, .{ .seed = 5, .text = "make it dark and moody" });
    defer r2.deinit();
    try testing.expectEqual(types.Emotion.dark, r2.piece.attributes.emotion.?);
    var r3 = try generateStub(testing.allocator, .{ .seed = 9 });
    defer r3.deinit();
    try testing.expect(r3.piece.attributes.key != null and r3.piece.attributes.tempo_bpm != null);
    var r4 = try generateStub(testing.allocator, .{ .seed = 9, .attributes = .{ .tempo_bpm = 150 } });
    defer r4.deinit();
    try testing.expectEqual(@as(f32, 150), r4.piece.attributes.tempo_bpm.?);
}

test "piece ends on the tonic, is deterministic and seeds differ" {
    var a = try generateStub(testing.allocator, .{ .bars = 8, .seed = 77 });
    defer a.deinit();
    var b = try generateStub(testing.allocator, .{ .bars = 8, .seed = 77 });
    defer b.deinit();
    var c = try generateStub(testing.allocator, .{ .bars = 8, .seed = 78 });
    defer c.deinit();
    const ma = a.piece.tracks[0].events;
    const mb = b.piece.tracks[0].events;
    const mc = c.piece.tracks[0].events;
    try testing.expectEqual(ma.len, mb.len);
    for (ma, mb) |x, y| try testing.expectEqual(x, y);
    var same = ma.len == mc.len;
    if (same) for (ma, mc) |x, y| {
        if (x.pitch != y.pitch or x.start_tick != y.start_tick) same = false;
    };
    try testing.expect(!same);
    const last = ma[ma.len - 1];
    try testing.expectEqual(@as(u8, @intCast(a.piece.attributes.key.?.tonic)), last.pitch % 12);
    try testing.expectEqual(TICKS_PER_BAR, last.duration_ticks);
}

test "request size is capped and runs are leak-free" {
    var r = try generateStub(testing.allocator, .{ .bars = 60000, .seed = 1 });
    defer r.deinit();
    var total: usize = 0;
    for (r.piece.tracks) |t| total += t.events.len;
    try testing.expect(total <= @as(usize, MAX_GEN_BARS) * MAX_BAR_NOTES);
    try testing.expectEqual(@as(?u16, MAX_GEN_BARS), r.piece.attributes.bars);
}

test "melody is varied: several durations, dynamics, stepwise motion" {
    var agg = metrics.MelodyStats{};
    var seed: u64 = 1;
    while (seed <= 60) : (seed += 1) {
        var r = try generateStub(testing.allocator, .{ .bars = 8, .seed = seed });
        defer r.deinit();
        const k = r.piece.attributes.key.?;
        metrics.add(&agg, metrics.melodyStats(r.piece.tracks[0].events, k.tonic, k.mode));
    }
    const P = metrics.MelodyStats.pct;
    try testing.expect(P(agg.in_key, agg.n) > 99.9);
    try testing.expect(P(agg.steps, agg.intervals) > 40.0);
    try testing.expect(P(agg.big_leaps, agg.intervals) < 12.0);
    try testing.expect(@as(f64, @floatFromInt(agg.distinct_dur)) / 60.0 >= 3.0);
    try testing.expect(agg.vel_sd / 60.0 > 4.0);
}
