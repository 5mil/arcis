//! Objective quality metrics over generated note lists (used by tests and the
//! benchmark harness). Allocation-free, O(n).

const std = @import("std");
const types = @import("types.zig");
const theory = @import("theory.zig");

pub const TICKS_PER_BAR: u32 = 1920;

pub const MelodyStats = struct {
    n: usize = 0,
    in_key: usize = 0,
    steps: usize = 0, // 1..2 semitones
    repeats: usize = 0, // same pitch
    leaps: usize = 0, // >= 5 semitones
    big_leaps: usize = 0, // > 7 semitones
    intervals: usize = 0,
    distinct_dur: usize = 0,
    vel_mean: f64 = 0,
    vel_sd: f64 = 0,
    bars: usize = 0,
    unique_bar_rhythms: usize = 0,
    repeated_bar_rhythms: usize = 0, // bars whose rhythm matched an earlier bar

    pub fn pct(part: usize, whole: usize) f64 {
        if (whole == 0) return 0;
        return 100.0 * @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole));
    }
};

fn gridPos(t: u32) u32 {
    return ((t % TICKS_PER_BAR) + 60) / 120;
}

pub fn inKey(pitch: u8, tonic_pc: u4, mode: types.Mode) bool {
    const pc: i32 = @mod(@as(i32, pitch) - tonic_pc, 12);
    for (theory.scales[@intFromEnum(mode)]) |o| if (@as(i32, o) == pc) return true;
    return false;
}

/// `notes` must be time-ordered (as every generator here emits).
pub fn melodyStats(notes: []const types.MidiNote, tonic_pc: u4, mode: types.Mode) MelodyStats {
    var s = MelodyStats{};
    s.n = notes.len;
    if (notes.len == 0) return s;
    var durs: [64]u32 = undefined;
    var nd: usize = 0;
    var vsum: f64 = 0;
    var vsq: f64 = 0;
    var prev: ?u8 = null;
    for (notes) |nt| {
        if (inKey(nt.pitch, tonic_pc, mode)) s.in_key += 1;
        const v: f64 = @floatFromInt(nt.velocity);
        vsum += v;
        vsq += v * v;
        const d = (nt.duration_ticks + 60) / 120;
        var seen = false;
        for (durs[0..nd]) |x| if (x == d) {
            seen = true;
            break;
        };
        if (!seen and nd < durs.len) {
            durs[nd] = d;
            nd += 1;
        }
        if (prev) |p| {
            const iv: u32 = @abs(@as(i32, nt.pitch) - p);
            s.intervals += 1;
            if (iv == 0) s.repeats += 1 else if (iv <= 2) s.steps += 1;
            if (iv >= 5) s.leaps += 1;
            if (iv > 7) s.big_leaps += 1;
        }
        prev = nt.pitch;
    }
    s.distinct_dur = nd;
    const n: f64 = @floatFromInt(notes.len);
    s.vel_mean = vsum / n;
    s.vel_sd = @sqrt(@max(vsq / n - s.vel_mean * s.vel_mean, 0));

    // Bar rhythm fingerprints
    var fps: [128]u64 = undefined;
    var nf: usize = 0;
    var i: usize = 0;
    while (i < notes.len) {
        const bar = notes[i].start_tick / TICKS_PER_BAR;
        var h = std.hash.Wyhash.init(0);
        while (i < notes.len and notes[i].start_tick / TICKS_PER_BAR == bar) : (i += 1) {
            h.update(std.mem.asBytes(&gridPos(notes[i].start_tick)));
            const d = (notes[i].duration_ticks + 60) / 120;
            h.update(std.mem.asBytes(&d));
        }
        const fp = h.final();
        s.bars += 1;
        var found = false;
        for (fps[0..nf]) |x| if (x == fp) {
            found = true;
            break;
        };
        if (found) {
            s.repeated_bar_rhythms += 1;
        } else if (nf < fps.len) {
            fps[nf] = fp;
            nf += 1;
        }
    }
    s.unique_bar_rhythms = nf;
    return s;
}

pub fn barNotes(notes: []const types.MidiNote, b: u32) []const types.MidiNote {
    var lo: usize = 0;
    while (lo < notes.len and notes[lo].start_tick / TICKS_PER_BAR < b) lo += 1;
    var hi = lo;
    while (hi < notes.len and notes[hi].start_tick / TICKS_PER_BAR == b) hi += 1;
    return notes[lo..hi];
}

/// Rhythm fingerprint of one bar (grid position + duration of each note).
pub fn barRhythm(notes: []const types.MidiNote, b: u32) u64 {
    var h = std.hash.Wyhash.init(0);
    for (barNotes(notes, b)) |nt| {
        h.update(std.mem.asBytes(&gridPos(nt.start_tick)));
        const d = (nt.duration_ticks + 60) / 120;
        h.update(std.mem.asBytes(&d));
    }
    return h.final();
}

pub fn printStats(label: []const u8, agg: MelodyStats, runs: usize) void {
    const P = MelodyStats.pct;
    std.debug.print(
        "{s}: runs={d} notes={d}  in-key={d:.1}%  stepwise={d:.1}% repeats={d:.1}% leaps(>=5st)={d:.1}% big-leaps(>7st)={d:.1}%  distinct-dur/run={d:.1}  vel-mean={d:.1} vel-sd={d:.1}  unique-bar-rhythms={d:.1}/{d:.1} bars (repeated={d:.1}%)\n",
        .{
            label,                                                                 runs,                                                       agg.n,
            P(agg.in_key, agg.n),                                                  P(agg.steps, agg.intervals),                               P(agg.repeats, agg.intervals),
            P(agg.leaps, agg.intervals),                                           P(agg.big_leaps, agg.intervals),
            @as(f64, @floatFromInt(agg.distinct_dur)) / @as(f64, @floatFromInt(runs)),
            agg.vel_mean / @as(f64, @floatFromInt(runs)),                          agg.vel_sd / @as(f64, @floatFromInt(runs)),
            @as(f64, @floatFromInt(agg.unique_bar_rhythms)) / @as(f64, @floatFromInt(runs)),
            @as(f64, @floatFromInt(agg.bars)) / @as(f64, @floatFromInt(runs)),
            P(agg.repeated_bar_rhythms, agg.bars),
        },
    );
}

pub fn add(agg: *MelodyStats, s: MelodyStats) void {
    agg.n += s.n;
    agg.in_key += s.in_key;
    agg.steps += s.steps;
    agg.repeats += s.repeats;
    agg.leaps += s.leaps;
    agg.big_leaps += s.big_leaps;
    agg.intervals += s.intervals;
    agg.distinct_dur += s.distinct_dur;
    agg.vel_mean += s.vel_mean;
    agg.vel_sd += s.vel_sd;
    agg.bars += s.bars;
    agg.unique_bar_rhythms += s.unique_bar_rhythms;
    agg.repeated_bar_rhythms += s.repeated_bar_rhythms;
}
