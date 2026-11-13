//! Objective before/after benchmark for Melos generation quality.
//! Run: zig run src/media/melos/melos_bench.zig
const std = @import("std");
const types = @import("types.zig");
const theory = @import("theory.zig");
const generate = @import("generate.zig");
const metrics = @import("metrics.zig");

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
}
