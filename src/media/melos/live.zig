//! Melos live performance session.
//! One `LiveState` = one running set: a `Composer` that advances one bar per
//! step (tick advance, per-bar seed mixing, A A' B cadence phrase plan, motif
//! memory) with no heap allocation per step.

const std = @import("std");
const types = @import("types.zig");
const generate = @import("generate.zig");
const theory = @import("theory.zig");

pub const TICKS_PER_BAR = generate.TICKS_PER_BAR;

pub const LiveState = struct {
    comp: generate.Composer,
    /// Start tick of the NEXT bar to be produced.
    current_tick: u32 = 0,
    /// Bars produced so far.
    steps: u32 = 0,
    base_prompt: [64]u8 = undefined,
    base_len: u8 = 0,
    tgt: Targets = undefined,

    pub fn init(seed: u64, base_prompt: ?[]const u8, attrs: ?types.MusicAttributes) LiveState {
        var s = LiveState{ .comp = undefined };
        const bp = base_prompt orelse "";
        const n = @min(bp.len, s.base_prompt.len);
        @memcpy(s.base_prompt[0..n], bp[0..n]);
        s.base_len = @intCast(n);
        s.comp = generate.Composer.init(.{ .text = bp, .attributes = attrs, .seed = seed });
        s.tgt = Targets.from(s.comp.p);
        return s;
    }

    pub fn basePrompt(self: *const LiveState) []const u8 {
        return self.base_prompt[0..self.base_len];
    }

    /// Move live parameters toward their targets: bounded per-bar slew, and
    /// structural changes (mode, register, sevenths) only on phrase boundaries.
    fn smooth(self: *LiveState) void {
        const p = &self.comp.p;
        p.tempo_bpm = approach(p.tempo_bpm, self.tgt.tempo, 8);
        p.density = approach(p.density, self.tgt.density, 0.08);
        p.energy = approach(p.energy, self.tgt.energy, 0.08);
        p.syncopation = approach(p.syncopation, self.tgt.syncopation, 0.1);
        if (self.comp.bar_index % 4 == 0) {
            if (p.register < self.tgt.register) p.register += 1;
            if (p.register > self.tgt.register) p.register -= 1;
            p.seventh = self.tgt.seventh;
            if (self.tgt.mode) |m| {
                if (m != self.comp.mode) self.comp.setKey(self.comp.tonic, m);
                self.tgt.mode = null;
            }
        }
        p.clamp();
    }

    /// Produce the next bar into `out`. Returns the bar's start tick.
    pub fn step(self: *LiveState, out: *generate.BarOut) u32 {
        const start = self.current_tick;
        self.smooth();
        self.comp.nextBar(out);
        self.steps += 1;
        self.current_tick = start + TICKS_PER_BAR;
        return start;
    }
};

// ---------------------------------------------------------------------------
// Crowd modulation: keywords -> continuous targets, smoothed over bars
// ---------------------------------------------------------------------------

pub const Targets = struct {
    tempo: f32,
    density: f32,
    energy: f32,
    syncopation: f32,
    register: i8,
    seventh: bool,
    mode: ?types.Mode = null,

    pub fn from(p: generate.Params) Targets {
        return .{ .tempo = p.tempo_bpm, .density = p.density, .energy = p.energy, .syncopation = p.syncopation, .register = p.register, .seventh = p.seventh };
    }

    fn clampAll(self: *Targets) void {
        self.tempo = std.math.clamp(self.tempo, 40, 220);
        self.density = std.math.clamp(self.density, 0.05, 1.0);
        self.energy = std.math.clamp(self.energy, 0.05, 1.0);
        self.syncopation = std.math.clamp(self.syncopation, 0, 1);
        self.register = std.math.clamp(self.register, -7, 7);
    }
};

const Effect = enum {
    faster,
    slower,
    energize,
    soften,
    busier,
    sparser,
    groove,
    straight,
    higher,
    lower,
    happy,
    bright,
    sad,
    dark,
    tense,
    calm,
    relax,
    jazz,
    plain,
};

const Rule = struct { kw: []const u8, fx: Effect };

const rules = [_]Rule{
    .{ .kw = "fast", .fx = .faster },     .{ .kw = "speed", .fx = .faster },      .{ .kw = "hurry", .fx = .faster },
    .{ .kw = "quick", .fx = .faster },    .{ .kw = "uptempo", .fx = .faster },    .{ .kw = "slow", .fx = .slower },
    .{ .kw = "drag", .fx = .slower },     .{ .kw = "energ", .fx = .energize },    .{ .kw = "hype", .fx = .energize },
    .{ .kw = "intens", .fx = .energize }, .{ .kw = "loud", .fx = .energize },     .{ .kw = "epic", .fx = .energize },
    .{ .kw = "pump", .fx = .energize },   .{ .kw = "soft", .fx = .soften },       .{ .kw = "quiet", .fx = .soften },
    .{ .kw = "gentle", .fx = .soften },   .{ .kw = "mellow", .fx = .soften },     .{ .kw = "whisper", .fx = .soften },
    .{ .kw = "busy", .fx = .busier },     .{ .kw = "dense", .fx = .busier },      .{ .kw = "complex", .fx = .busier },
    .{ .kw = "frantic", .fx = .busier },  .{ .kw = "sparse", .fx = .sparser },    .{ .kw = "simple", .fx = .sparser },
    .{ .kw = "minimal", .fx = .sparser }, .{ .kw = "space", .fx = .sparser },     .{ .kw = "groov", .fx = .groove },
    .{ .kw = "funk", .fx = .groove },     .{ .kw = "swing", .fx = .groove },      .{ .kw = "syncop", .fx = .groove },
    .{ .kw = "bounce", .fx = .groove },   .{ .kw = "straight", .fx = .straight }, .{ .kw = "steady", .fx = .straight },
    .{ .kw = "march", .fx = .straight },  .{ .kw = "high", .fx = .higher },       .{ .kw = "sky", .fx = .higher },
    .{ .kw = "soar", .fx = .higher },     .{ .kw = "low", .fx = .lower },         .{ .kw = "deep", .fx = .lower },
    .{ .kw = "happy", .fx = .happy },     .{ .kw = "joy", .fx = .happy },         .{ .kw = "sunny", .fx = .happy },
    .{ .kw = "bright", .fx = .bright },   .{ .kw = "sad", .fx = .sad },           .{ .kw = "melanchol", .fx = .sad },
    .{ .kw = "blue", .fx = .sad },        .{ .kw = "dark", .fx = .dark },         .{ .kw = "moody", .fx = .dark },
    .{ .kw = "tense", .fx = .tense },     .{ .kw = "spook", .fx = .tense },       .{ .kw = "eerie", .fx = .tense },
    .{ .kw = "ominous", .fx = .tense },   .{ .kw = "calm", .fx = .calm },         .{ .kw = "chill", .fx = .calm },
    .{ .kw = "peace", .fx = .calm },      .{ .kw = "relax", .fx = .relax },       .{ .kw = "jazz", .fx = .jazz },
    .{ .kw = "seventh", .fx = .jazz },    .{ .kw = "lush", .fx = .jazz },         .{ .kw = "plain", .fx = .plain },
};

pub const MAX_PROMPT = 200;

pub const Applied = struct {
    labels: [8][]const u8 = undefined,
    n: usize = 0,
    fn add(self: *Applied, l: []const u8) void {
        for (self.labels[0..self.n]) |x| if (std.mem.eql(u8, x, l)) return;
        if (self.n < self.labels.len) {
            self.labels[self.n] = l;
            self.n += 1;
        }
    }
};

/// Move the live targets according to a crowd prompt (case-insensitive,
/// whole-word-prefix keywords, effects stack and clamp). O(len * rules).
pub fn applyPrompt(tgt: *Targets, prompt: []const u8, applied: *Applied) void {
    var buf: [MAX_PROMPT]u8 = undefined;
    const n = @min(prompt.len, MAX_PROMPT);
    for (prompt[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    var it = std.mem.tokenizeAny(u8, buf[0..n], " \t\r\n,.;:!?\"'()[]{}-_/");
    var words: usize = 0;
    while (it.next()) |w| {
        words += 1;
        if (words > 24) break;
        for (rules) |r| {
            if (!std.mem.startsWith(u8, w, r.kw)) continue;
            switch (r.fx) {
                .faster => {
                    tgt.tempo += 20;
                    applied.add("tempo up");
                },
                .slower => {
                    tgt.tempo -= 20;
                    applied.add("tempo down");
                },
                .energize => {
                    tgt.energy += 0.25;
                    tgt.density += 0.15;
                    tgt.tempo += 10;
                    applied.add("energy up");
                },
                .soften => {
                    tgt.energy -= 0.25;
                    tgt.density -= 0.1;
                    applied.add("softer");
                },
                .busier => {
                    tgt.density += 0.2;
                    applied.add("busier");
                },
                .sparser => {
                    tgt.density -= 0.2;
                    applied.add("sparser");
                },
                .groove => {
                    tgt.syncopation += 0.3;
                    applied.add("more groove");
                },
                .straight => {
                    tgt.syncopation -= 0.3;
                    applied.add("straighter");
                },
                .higher => {
                    tgt.register += 2;
                    applied.add("higher register");
                },
                .lower => {
                    tgt.register -= 2;
                    applied.add("lower register");
                },
                .happy => {
                    tgt.mode = .major;
                    tgt.tempo += 8;
                    tgt.energy += 0.1;
                    applied.add("mode major");
                },
                .bright => {
                    tgt.mode = .lydian;
                    tgt.tempo += 8;
                    tgt.energy += 0.1;
                    applied.add("mode lydian");
                },
                .sad => {
                    tgt.mode = .minor;
                    tgt.tempo -= 10;
                    tgt.energy -= 0.1;
                    applied.add("mode minor");
                },
                .dark => {
                    tgt.mode = .minor;
                    tgt.energy += 0.05;
                    applied.add("mode minor");
                },
                .tense => {
                    tgt.mode = .phrygian;
                    tgt.syncopation += 0.15;
                    applied.add("mode phrygian");
                },
                .calm => {
                    tgt.mode = .dorian;
                    tgt.tempo -= 12;
                    tgt.energy -= 0.15;
                    tgt.density -= 0.1;
                    applied.add("mode dorian");
                },
                .relax => {
                    tgt.mode = .mixolydian;
                    tgt.tempo -= 8;
                    tgt.energy -= 0.1;
                    applied.add("mode mixolydian");
                },
                .jazz => {
                    tgt.seventh = true;
                    applied.add("sevenths on");
                },
                .plain => {
                    tgt.seventh = false;
                    applied.add("sevenths off");
                },
            }
            break; // one rule per word
        }
    }
    tgt.clampAll();
}

fn approach(cur: f32, target: f32, max_step: f32) f32 {
    return cur + std.math.clamp(target - cur, -max_step, max_step);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const metrics = @import("metrics.zig");

test "live ticks advance one bar per step and notes stay inside their bar" {
    var st = LiveState.init(11, "ambient", null);
    var bo = generate.BarOut{};
    var expect: u32 = 0;
    for (0..40) |_| {
        const t = st.step(&bo);
        try testing.expectEqual(expect, t);
        expect += TICKS_PER_BAR;
        for (bo.melody[0..bo.mel_n]) |n| try testing.expect(n.start_tick + 24 >= t and n.start_tick < t + TICKS_PER_BAR + 24);
        for (bo.pad[0..bo.pad_n]) |n| try testing.expectEqual(t, n.start_tick);
    }
    try testing.expectEqual(@as(u32, 40), st.steps);
    try testing.expectEqual(expect, st.current_tick);
}

test "outputs differ across steps and across sessions" {
    var st = LiveState.init(21, null, null);
    var bo = generate.BarOut{};
    var seen: [16]u64 = undefined;
    var uniq: usize = 0;
    for (0..16) |_| {
        _ = st.step(&bo);
        var h = std.hash.Wyhash.init(0);
        for (bo.melody[0..bo.mel_n]) |n| {
            h.update(std.mem.asBytes(&n.pitch));
            h.update(std.mem.asBytes(&n.duration_ticks));
        }
        const f = h.final();
        var dup = false;
        for (seen[0..uniq]) |x| if (x == f) {
            dup = true;
        };
        if (!dup) {
            seen[uniq] = f;
            uniq += 1;
        }
    }
    try testing.expect(uniq >= 12);
    // different seeds -> different 8-bar melodies; same seed -> identical
    var a = LiveState.init(21, null, null);
    var b = LiveState.init(22, null, null);
    var c = LiveState.init(21, null, null);
    var ba = generate.BarOut{};
    var bb = generate.BarOut{};
    var bc = generate.BarOut{};
    var diff_ab: usize = 0;
    for (0..8) |_| {
        _ = a.step(&ba);
        _ = b.step(&bb);
        _ = c.step(&bc);
        try testing.expectEqual(ba.mel_n, bc.mel_n);
        for (ba.melody[0..ba.mel_n], bc.melody[0..bc.mel_n]) |x, y| try testing.expectEqual(x, y);
        if (ba.mel_n != bb.mel_n or ba.melody[0].pitch != bb.melody[0].pitch) diff_ab += 1;
    }
    try testing.expect(diff_ab > 0);
}

test "phrase plan A A' B cadence over a 16-bar period, final bar is a held tonic" {
    var st = LiveState.init(5, null, null);
    var bo = generate.BarOut{};
    const names = [4]generate.Phrase{ .A, .A2, .B, .cadence };
    for (0..32) |i| {
        _ = st.step(&bo);
        try testing.expectEqual(names[(i % 16) / 4], bo.phrase);
        try testing.expectEqual(@as(u8, @intCast(i % 4)), bo.bar_in_phrase);
        if (i % 16 == 15) {
            try testing.expect(bo.is_final);
            try testing.expectEqual(@as(usize, 1), bo.mel_n);
            try testing.expectEqual(@as(u8, @intCast(st.comp.tonic)), bo.melody[0].pitch % 12);
            try testing.expectEqual(@as(u8, 0), bo.chord_deg);
        }
    }
}

test "motif recurrence: repeats, A' restates A, B inverts, cadence echoes A" {
    var hits_rep: usize = 0;
    var hits_a2: usize = 0;
    var hits_cad: usize = 0;
    const runs: usize = 60;
    for (0..runs) |r| {
        var st = LiveState.init(1000 + r, null, null);
        var bars: [16][generate.MAX_MEL]types.MidiNote = undefined;
        var counts: [16]usize = undefined;
        var bo = generate.BarOut{};
        for (0..16) |i| {
            _ = st.step(&bo);
            counts[i] = bo.mel_n;
            @memcpy(bars[i][0..bo.mel_n], bo.melody[0..bo.mel_n]);
        }
        const fp = struct {
            fn of(b: []const types.MidiNote) u64 {
                var h = std.hash.Wyhash.init(0);
                for (b) |n| {
                    const g = ((n.start_tick % TICKS_PER_BAR) + 60) / 120;
                    const d = (n.duration_ticks + 60) / 120;
                    h.update(std.mem.asBytes(&g));
                    h.update(std.mem.asBytes(&d));
                }
                return h.final();
            }
        }.of;
        if (fp(bars[1][0..counts[1]]) == fp(bars[0][0..counts[0]])) hits_rep += 1; // repeat
        if (fp(bars[4][0..counts[4]]) == fp(bars[0][0..counts[0]])) hits_a2 += 1; // A' bar 0 = A bar 0
        // cadence fragment keeps the first half of motif A
        const a = bars[0][0..counts[0]];
        const c = bars[12][0..counts[12]];
        var same_first_half = true;
        var ia: usize = 0;
        var ic: usize = 0;
        while (ia < a.len and ic < c.len) {
            const ga = ((a[ia].start_tick % TICKS_PER_BAR) + 60) / 120;
            if (ga >= 8) break;
            const gc = ((c[ic].start_tick % TICKS_PER_BAR) + 60) / 120;
            if (ga != gc) same_first_half = false;
            ia += 1;
            ic += 1;
        }
        if (same_first_half) hits_cad += 1;
    }
    try testing.expectEqual(runs, hits_rep);
    try testing.expectEqual(runs, hits_a2);
    try testing.expectEqual(runs, hits_cad);
}

test "live melody keeps strong beats on chord tones and stays in key" {
    var st = LiveState.init(31, "calm", null);
    var bo = generate.BarOut{};
    for (0..64) |_| {
        _ = st.step(&bo);
        for (bo.melody[0..bo.mel_n]) |n| {
            try testing.expect(metrics.inKey(n.pitch, st.comp.tonic, st.comp.mode));
            if (((n.start_tick % TICKS_PER_BAR) + 60) / 120 % 8 != 0) continue;
            const d: i32 = bo.chord_deg;
            const pc = n.pitch % 12;
            const ok = pc == theory.stepPc(st.comp.tonic, st.comp.mode, d) or
                pc == theory.stepPc(st.comp.tonic, st.comp.mode, d + 2) or
                pc == theory.stepPc(st.comp.tonic, st.comp.mode, d + 4);
            try testing.expect(ok);
        }
    }
}

test "modulate changes tempo (smoothly), mode (at phrase boundary), density and register" {
    var st = LiveState.init(77, "calm", .{ .tempo_bpm = 100, .key = .{ .tonic = 0, .mode = .major } });
    var bo = generate.BarOut{};
    _ = st.step(&bo);
    const t0 = st.comp.p.tempo_bpm;
    var ap = Applied{};
    applyPrompt(&st.tgt, "Make it FASTER and Brighter, more groove!", &ap);
    try testing.expect(ap.n >= 3);
    try testing.expect(st.tgt.tempo > t0 + 20);
    var prev = st.comp.p.tempo_bpm;
    var saw_mode_change = false;
    for (0..12) |_| {
        _ = st.step(&bo);
        const t = st.comp.p.tempo_bpm;
        try testing.expect(t >= prev and t - prev <= 8.001); // monotone, slew-limited
        prev = t;
        if (st.comp.mode == .lydian) saw_mode_change = true;
    }
    try testing.expect(prev > t0 + 20);
    try testing.expect(saw_mode_change);
    try testing.expectEqual(types.Mode.lydian, st.comp.mode);
    // mode switches only at phrase boundaries
    var st2 = LiveState.init(78, null, .{ .key = .{ .tonic = 0, .mode = .major } });
    _ = st2.step(&bo);
    _ = st2.step(&bo); // bar 1 done; next bar index 2
    applyPrompt(&st2.tgt, "dark", &ap);
    _ = st2.step(&bo); // bar 2
    try testing.expectEqual(types.Mode.major, st2.comp.mode);
    _ = st2.step(&bo); // bar 3
    try testing.expectEqual(types.Mode.major, st2.comp.mode);
    _ = st2.step(&bo); // bar 4 -> phrase boundary
    try testing.expectEqual(types.Mode.minor, st2.comp.mode);
}

test "density modulation changes note counts, energy changes velocities, register moves pitch" {
    const count = struct {
        fn run(prompt: ?[]const u8) struct { notes: usize, vel: f64, pitch: f64 } {
            var st = LiveState.init(123, null, .{ .key = .{ .tonic = 0, .mode = .major } });
            var bo = generate.BarOut{};
            var ap = Applied{};
            if (prompt) |p| applyPrompt(&st.tgt, p, &ap);
            var notes: usize = 0;
            var vel: f64 = 0;
            var pitch: f64 = 0;
            for (0..32) |i| {
                _ = st.step(&bo);
                if (i < 16) continue; // measure after the slew has settled
                notes += bo.mel_n;
                for (bo.melody[0..bo.mel_n]) |n| {
                    vel += @floatFromInt(n.velocity);
                    pitch += @floatFromInt(n.pitch);
                }
            }
            const nn: f64 = @floatFromInt(@max(notes, 1));
            return .{ .notes = notes, .vel = vel / nn, .pitch = pitch / nn };
        }
    }.run;
    const base = count(null);
    const busy = count("busy and frantic, so dense");
    const sparse = count("sparse minimal and simple");
    try testing.expect(busy.notes > base.notes);
    try testing.expect(sparse.notes < base.notes);
    const loud = count("loud epic energetic");
    const soft = count("soft whisper gentle");
    try testing.expect(loud.vel > base.vel + 4);
    try testing.expect(soft.vel < base.vel - 4);
    const hi = count("higher higher sky soar");
    const lo = count("lower deeper low");
    try testing.expect(hi.pitch > lo.pitch + 3);
}

test "prompt parsing is case-insensitive, word-based and bounded" {
    var t = Targets.from(.{});
    var ap = Applied{};
    applyPrompt(&t, "SLOW", &ap);
    try testing.expect(t.tempo < 100); // "slow" is not "low"
    try testing.expect(t.register == 0);
    var big: [4000]u8 = undefined;
    @memset(&big, 'x');
    var t2 = Targets.from(.{});
    var ap2 = Applied{};
    applyPrompt(&t2, &big, &ap2);
    try testing.expectEqual(@as(usize, 0), ap2.n);
}
