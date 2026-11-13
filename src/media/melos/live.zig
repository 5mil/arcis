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

    pub fn init(seed: u64, base_prompt: ?[]const u8, attrs: ?types.MusicAttributes) LiveState {
        var s = LiveState{ .comp = undefined };
        const bp = base_prompt orelse "";
        const n = @min(bp.len, s.base_prompt.len);
        @memcpy(s.base_prompt[0..n], bp[0..n]);
        s.base_len = @intCast(n);
        s.comp = generate.Composer.init(.{ .text = bp, .attributes = attrs, .seed = seed });
        return s;
    }

    pub fn basePrompt(self: *const LiveState) []const u8 {
        return self.base_prompt[0..self.base_len];
    }

    /// Produce the next bar into `out`. Returns the bar's start tick.
    pub fn step(self: *LiveState, out: *generate.BarOut) u32 {
        const start = self.current_tick;
        self.comp.nextBar(out);
        self.steps += 1;
        self.current_tick = start + TICKS_PER_BAR;
        return start;
    }
};

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
