//! Objective before/after benchmark for Melos generation quality.
//! Run: zig run src/media/melos/melos_bench.zig
const std = @import("std");
const types = @import("types.zig");
const theory = @import("theory.zig");
const generate = @import("generate.zig");
const metrics = @import("metrics.zig");
const live = @import("live.zig");

pub fn main() !void {
    const a = std.heap.page_allocator;
    var agg = metrics.MelodyStats{};
    var runs: usize = 0;
    var chord_hits: usize = 0;
    var chord_total: usize = 0;
    var seed: u64 = 1;
    while (seed <= 200) : (seed += 1) {
        var r = try generate.generateStub(a, .{ .bars = 8, .seed = seed });
        defer r.deinit();
        const k = r.piece.attributes.key.?;
        metrics.add(&agg, metrics.melodyStats(r.piece.tracks[0].events, k.tonic, k.mode));
        runs += 1;
        var c = generate.Composer.init(.{ .bars = 8, .seed = seed });
        c.finite_bars = 8;
        var bo = generate.BarOut{};
        for (0..8) |_| {
            c.nextBar(&bo);
            for (bo.melody[0..bo.mel_n]) |nt| {
                if (((nt.start_tick % 1920) + 60) / 120 % 8 != 0) continue;
                chord_total += 1;
                const d: i32 = bo.chord_deg;
                const pc = nt.pitch % 12;
                if (pc == theory.stepPc(c.tonic, c.mode, d) or pc == theory.stepPc(c.tonic, c.mode, d + 2) or pc == theory.stepPc(c.tonic, c.mode, d + 4)) chord_hits += 1;
            }
        }
    }
    metrics.printStats("NEW  generate 8 bars (vs its own key)", agg, runs);
    std.debug.print("NEW  strong-beat chord-tone rate = {d:.1}% ({d} strong-beat melody notes)\n", .{ metrics.MelodyStats.pct(chord_hits, chord_total), chord_total });

    // Stage 1: 16 consecutive live steps (one 16-bar period), averaged over 100 sets.
    var agg2 = metrics.MelodyStats{};
    var uniq_total: usize = 0;
    var last_tick_max: u32 = 0;
    var sets: usize = 0;
    var s2: u64 = 1;
    while (s2 <= 100) : (s2 += 1) {
        var st = live.LiveState.init(s2, "ambient", null);
        var all: [16 * generate.MAX_MEL]types.MidiNote = undefined;
        var n: usize = 0;
        var hs: [16]u64 = undefined;
        var uniq: usize = 0;
        var bo = generate.BarOut{};
        for (0..16) |_| {
            _ = st.step(&bo);
            var h = std.hash.Wyhash.init(0);
            for (bo.melody[0..bo.mel_n]) |nt| {
                h.update(std.mem.asBytes(&nt.pitch));
                all[n] = nt;
                n += 1;
            }
            const f = h.final();
            var seen = false;
            for (hs[0..uniq]) |x| if (x == f) {
                seen = true;
            };
            if (!seen) {
                hs[uniq] = f;
                uniq += 1;
            }
            last_tick_max = @max(last_tick_max, bo.melody[bo.mel_n - 1].start_tick);
        }
        uniq_total += uniq;
        metrics.add(&agg2, metrics.melodyStats(all[0..n], st.comp.tonic, st.comp.mode));
        sets += 1;
    }
    metrics.printStats("NEW  live 16 steps (vs its own key)", agg2, sets);
    std.debug.print("NEW  live: unique step pitch-sequences = {d:.1}/16, last note start_tick={d} (monotonic bars)\n", .{ @as(f64, @floatFromInt(uniq_total)) / @as(f64, @floatFromInt(sets)), last_tick_max });
}
