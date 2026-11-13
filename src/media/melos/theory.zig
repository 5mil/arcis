//! Melos music theory core: scales, diatonic chords, per-mode progressions and
//! cadences, emotion profiles, and parallel-free voice leading.
//! Pure functions, no allocation, O(1) per call.

const std = @import("std");
const types = @import("types.zig");

pub const Mode = types.Mode;
pub const Emotion = types.Emotion;

/// Semitone offsets of the seven scale degrees, indexed by @intFromEnum(Mode).
pub const scales = [6][7]u8{
    .{ 0, 2, 4, 5, 7, 9, 11 }, // major
    .{ 0, 2, 3, 5, 7, 8, 10 }, // natural minor
    .{ 0, 2, 3, 5, 7, 9, 10 }, // dorian
    .{ 0, 2, 4, 5, 7, 9, 10 }, // mixolydian
    .{ 0, 2, 4, 6, 7, 9, 11 }, // lydian
    .{ 0, 1, 3, 5, 7, 8, 10 }, // phrygian
};

pub fn modeName(m: Mode) []const u8 {
    return @tagName(m);
}

/// Semitone offset above the tonic of an (unbounded) scale step. Step 0 = tonic,
/// step 7 = tonic one octave up, step -1 = the degree below the tonic.
pub fn stepOffset(mode: Mode, step: i32) i32 {
    const sc = scales[@intFromEnum(mode)];
    return 12 * @divFloor(step, 7) + @as(i32, sc[@intCast(@mod(step, 7))]);
}

/// Pitch class (0-11) of a scale step given the tonic pitch class.
pub fn stepPc(tonic_pc: i32, mode: Mode, step: i32) u8 {
    return @intCast(@mod(tonic_pc + stepOffset(mode, step), 12));
}

/// True when `step` is a triad tone (root, third or fifth) of the diatonic chord
/// built on scale degree `root_deg`.
pub fn isChordStep(step: i32, root_deg: i32) bool {
    const d = @mod(step - root_deg, 7);
    return d == 0 or d == 2 or d == 4;
}

/// Nearest step to `step` (ties go down) that is a chord tone, searching +-3.
pub fn snapToChord(step: i32, root_deg: i32) i32 {
    var k: i32 = 0;
    while (k <= 3) : (k += 1) {
        if (isChordStep(step - k, root_deg)) return step - k;
        if (isChordStep(step + k, root_deg)) return step + k;
    }
    return step;
}

// ---------------------------------------------------------------------------
// Progressions (scale degrees, 0 = I/i). One chord per bar, four bars/phrase.
// ---------------------------------------------------------------------------

pub const Prog = [4]u8;

pub const progs = [6][4]Prog{
    // major: I V vi IV | I vi IV V | I IV V IV | I iii IV V
    .{ .{ 0, 4, 5, 3 }, .{ 0, 5, 3, 4 }, .{ 0, 3, 4, 3 }, .{ 0, 2, 3, 4 } },
    // minor: i VI III VII | i iv v i | i VII VI v | i VI iv VII
    .{ .{ 0, 5, 2, 6 }, .{ 0, 3, 4, 0 }, .{ 0, 6, 5, 4 }, .{ 0, 5, 3, 6 } },
    // dorian: i IV i VII | i IV VII IV | i VII IV i | i ii IV i
    .{ .{ 0, 3, 0, 6 }, .{ 0, 3, 6, 3 }, .{ 0, 6, 3, 0 }, .{ 0, 1, 3, 0 } },
    // mixolydian: I VII IV I | I IV VII I | I VII I IV | I VI VII IV
    .{ .{ 0, 6, 3, 0 }, .{ 0, 3, 6, 0 }, .{ 0, 6, 0, 3 }, .{ 0, 5, 6, 3 } },
    // lydian: I II I II | I II V I | I V II I | I iii II I
    .{ .{ 0, 1, 0, 1 }, .{ 0, 1, 4, 0 }, .{ 0, 4, 1, 0 }, .{ 0, 2, 1, 0 } },
    // phrygian: i bII i VII | i bII bIII bII | i VII bII i | i VI VII bII
    .{ .{ 0, 1, 0, 6 }, .{ 0, 1, 2, 1 }, .{ 0, 6, 1, 0 }, .{ 0, 5, 6, 1 } },
};

/// Four-bar closing phrase per mode. Index 2 is the penultimate (approach)
/// chord and index 3 always lands on the tonic.
pub const cadences = [6]Prog{
    .{ 0, 3, 4, 0 }, // major: I IV V I
    .{ 3, 5, 6, 0 }, // minor: iv VI VII i
    .{ 3, 6, 3, 0 }, // dorian
    .{ 3, 6, 3, 0 }, // mixolydian
    .{ 1, 4, 1, 0 }, // lydian
    .{ 3, 6, 1, 0 }, // phrygian
};

/// splitmix64 finalizer: cheap, high-quality seed mixing.
pub fn mix(a: u64, b: u64) u64 {
    var z = a +% 0x9E3779B97F4A7C15 +% (b *% 0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

// ---------------------------------------------------------------------------
// Emotion profiles
// ---------------------------------------------------------------------------

pub const Profile = struct {
    mode: Mode,
    tempo: f32,
    density: f32,
    energy: f32,
    syncopation: f32,
    seventh: bool,
};

pub fn emotionProfile(e: Emotion) Profile {
    return switch (e) {
        .happy => .{ .mode = .major, .tempo = 120, .density = 0.60, .energy = 0.70, .syncopation = 0.25, .seventh = false },
        .sad => .{ .mode = .minor, .tempo = 68, .density = 0.35, .energy = 0.35, .syncopation = 0.10, .seventh = true },
        .energetic => .{ .mode = .mixolydian, .tempo = 140, .density = 0.85, .energy = 0.90, .syncopation = 0.45, .seventh = false },
        .calm => .{ .mode = .dorian, .tempo = 78, .density = 0.30, .energy = 0.30, .syncopation = 0.10, .seventh = true },
        .dark => .{ .mode = .minor, .tempo = 84, .density = 0.45, .energy = 0.50, .syncopation = 0.20, .seventh = true },
        .bright => .{ .mode = .lydian, .tempo = 126, .density = 0.65, .energy = 0.75, .syncopation = 0.30, .seventh = false },
        .tense => .{ .mode = .phrygian, .tempo = 104, .density = 0.60, .energy = 0.65, .syncopation = 0.35, .seventh = true },
        .relaxed => .{ .mode = .mixolydian, .tempo = 90, .density = 0.40, .energy = 0.40, .syncopation = 0.30, .seventh = true },
    };
}

/// Friendly default tonics (C G D A F Bb E) picked from a seed.
pub fn defaultTonic(seed: u64) u4 {
    const pool = [_]u4{ 0, 7, 2, 9, 5, 10, 4 };
    return pool[@intCast(mix(seed, 0x7011C) % pool.len)];
}

pub fn defaultEmotion(seed: u64) Emotion {
    const pool = [_]Emotion{ .happy, .calm, .bright, .relaxed, .sad, .energetic };
    return pool[@intCast(mix(seed, 0xE30) % pool.len)];
}

/// MIDI pitch of the tonic used as melodic centre, in [54, 65].
pub fn tonicMidi(tonic_pc: u4) i32 {
    const t: i32 = tonic_pc;
    return 60 + t - (if (t > 6) @as(i32, 12) else 0);
}

pub fn pitchOf(tonic_mid: i32, mode: Mode, step: i32) u8 {
    return @intCast(std.math.clamp(tonic_mid + stepOffset(mode, step), 0, 127));
}

// ---------------------------------------------------------------------------
// Voice leading
// ---------------------------------------------------------------------------

pub const Voicing = struct {
    n: u8 = 0,
    p: [4]u8 = .{ 0, 0, 0, 0 },
};

fn sortVoices(v: *Voicing) void {
    var i: usize = 1;
    while (i < v.n) : (i += 1) {
        const x = v.p[i];
        var j = i;
        while (j > 0 and v.p[j - 1] > x) : (j -= 1) v.p[j] = v.p[j - 1];
        v.p[j] = x;
    }
}

/// Number of parallel fifths/octaves between two voicings (same voice index =
/// same voice). Both voices must move in the same direction by any amount.
pub fn parallels(a: Voicing, b: Voicing) u32 {
    const n = @min(a.n, b.n);
    var count: u32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var j = i + 1;
        while (j < n) : (j += 1) {
            const di = @as(i32, b.p[i]) - a.p[i];
            const dj = @as(i32, b.p[j]) - a.p[j];
            if (di == 0 or dj == 0) continue;
            if ((di > 0) != (dj > 0)) continue;
            const ia = @mod(@as(i32, a.p[j]) - a.p[i], 12);
            const ib = @mod(@as(i32, b.p[j]) - b.p[i], 12);
            if (ia == ib and (ia == 7 or ia == 0)) count += 1;
        }
    }
    return count;
}

/// Choose the best voicing of the given pitch classes: 2^n octave placements in
/// [low, low+23], minimising total voice movement from `prev`, rejecting
/// parallel fifths/octaves, and keeping the span compact.
pub fn voiceLead(prev: ?Voicing, pcs: [4]u8, n: u8, low: u8) Voicing {
    var best = Voicing{ .n = n };
    var best_cost: i32 = std.math.maxInt(i32);
    const combos: u32 = @as(u32, 1) << @intCast(n);
    var mask: u32 = 0;
    while (mask < combos) : (mask += 1) {
        var v = Voicing{ .n = n };
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const base: i32 = low + @mod(@as(i32, pcs[i]) - low, 12);
            v.p[i] = @intCast(base + 12 * @as(i32, @intCast((mask >> @intCast(i)) & 1)));
        }
        sortVoices(&v);
        const span: i32 = @as(i32, v.p[n - 1]) - v.p[0];
        var cost: i32 = 0;
        if (span > 12) cost += 4 * (span - 12);
        if (prev) |pv| {
            const m = @min(pv.n, n);
            var k: usize = 0;
            while (k < m) : (k += 1) cost += @intCast(@abs(@as(i32, v.p[k]) - pv.p[k]));
            cost += 100 * @as(i32, @intCast(parallels(pv, v)));
        } else {
            cost += span;
        }
        if (cost < best_cost) {
            best_cost = cost;
            best = v;
        }
    }
    return best;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "stepOffset covers scales and wraps octaves" {
    try std.testing.expectEqual(@as(i32, 0), stepOffset(.major, 0));
    try std.testing.expectEqual(@as(i32, 7), stepOffset(.major, 4));
    try std.testing.expectEqual(@as(i32, 12), stepOffset(.major, 7));
    try std.testing.expectEqual(@as(i32, -1), stepOffset(.major, -1));
    try std.testing.expectEqual(@as(i32, -2), stepOffset(.minor, -1));
    try std.testing.expectEqual(@as(i32, 6), stepOffset(.lydian, 3));
}

test "snapToChord lands on chord tones" {
    var deg: i32 = 0;
    while (deg < 7) : (deg += 1) {
        var s: i32 = -3;
        while (s < 14) : (s += 1) {
            const t = snapToChord(s, deg);
            try std.testing.expect(isChordStep(t, deg));
            try std.testing.expect(@abs(t - s) <= 1);
        }
    }
}

test "every progression starts on the tonic and cadences end on the tonic" {
    for (progs) |set| for (set) |p| try std.testing.expectEqual(@as(u8, 0), p[0]);
    for (cadences) |c| try std.testing.expectEqual(@as(u8, 0), c[3]);
}

test "voice leading has no parallel fifths or octaves across all progressions" {
    for (0..6) |mi| {
        const mode: Mode = @enumFromInt(mi);
        for (progs[mi]) |p| {
            for ([_]u8{ 3, 4 }) |nv| {
                var prev: ?Voicing = null;
                var round: usize = 0;
                while (round < 3) : (round += 1) {
                    for (p) |deg| {
                        var pcs: [4]u8 = .{ 0, 0, 0, 0 };
                        const steps = [4]i32{ deg, deg + 2, deg + 4, deg + 6 };
                        for (0..nv) |i| pcs[i] = stepPc(0, mode, steps[i]);
                        const v = voiceLead(prev, pcs, nv, 52);
                        if (prev) |pv| try std.testing.expectEqual(@as(u32, 0), parallels(pv, v));
                        for (0..nv) |i| try std.testing.expect(v.p[i] >= 52 and v.p[i] <= 52 + 24);
                        prev = v;
                    }
                }
            }
        }
    }
}
