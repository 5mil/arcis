//! rules.zig — phonetic and cultural rules for space/wizard name generation
//! Phase 9 — src/naming/
//! Implements authentic two-layer naming: cultural phonetic root + rank suffix
//! From v0.1.0 scope: authentic phonetics, cultural roots, status hierarchy, variant tracking.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Cultural tradition
// ---------------------------------------------------------------------------

pub const Tradition = enum {
    sumerian,
    akkadian,
    greek,
    latin,
    arabic,
    hebrew,
    norse,
    celtic,
    sanskrit,
    egyptian,
};

// ---------------------------------------------------------------------------
// Phoneme tables (onset, nucleus, coda)
// ---------------------------------------------------------------------------

const PhonemeTable = struct {
    onsets:  []const []const u8,
    nuclei:  []const []const u8,
    codas:   []const []const u8,
};

const GREEK = PhonemeTable{
    .onsets = &.{ "al", "ar", "kh", "kr", "ly", "mn", "ph", "pr", "th", "zy" },
    .nuclei = &.{ "a", "e", "ei", "eu", "i", "o", "ou", "u" },
    .codas  = &.{ "n", "s", "x", "r", "on", "os", "is", "as" },
};

const LATIN = PhonemeTable{
    .onsets = &.{ "aur", "cal", "cas", "fl", "jul", "luc", "mar", "syl", "val", "vir" },
    .nuclei = &.{ "a", "e", "i", "o", "u", "ae" },
    .codas  = &.{ "us", "a", "um", "ix", "or", "ius", "ia", "ius" },
};

const SUMERIAN = PhonemeTable{
    .onsets = &.{ "an", "en", "in", "ki", "nam", "nin", "ur", "ug", "zi", "zu" },
    .nuclei = &.{ "a", "e", "i", "u" },
    .codas  = &.{ "", "g", "k", "l", "m", "n", "r" },
};

const ARABIC = PhonemeTable{
    .onsets = &.{ "abd", "al", "dha", "fai", "hai", "kha", "nas", "qad", "rai", "zah" },
    .nuclei = &.{ "a", "i", "u", "aa", "ii", "uu" },
    .codas  = &.{ "n", "r", "l", "m", "d", "b", "s" },
};

const NORSE = PhonemeTable{
    .onsets = &.{ "alf", "bj", "dag", "eil", "frey", "gn", "hal", "isk", "ran", "sig" },
    .nuclei = &.{ "a", "e", "i", "o", "u", "yr" },
    .codas  = &.{ "r", "n", "l", "vik", "str", "mund", "rik", "gar" },
};

const SANSKRIT = PhonemeTable{
    .onsets = &.{ "bra", "dha", "ind", "kri", "man", "pra", "raj", "sha", "sri", "var" },
    .nuclei = &.{ "a", "aa", "i", "ii", "u", "e", "ai", "o" },
    .codas  = &.{ "m", "n", "h", "ra", "va", "ta", "ya", "tha" },
};

fn tableFor(t: Tradition) PhonemeTable {
    return switch (t) {
        .greek     => GREEK,
        .latin     => LATIN,
        .sumerian  => SUMERIAN,
        .arabic    => ARABIC,
        .norse     => NORSE,
        .sanskrit  => SANSKRIT,
        // Remaining traditions fall back to Greek for now.
        else       => GREEK,
    };
}

// ---------------------------------------------------------------------------
// Rank hierarchy
// ---------------------------------------------------------------------------

pub const Rank = enum {
    initiate,
    adept,
    scholar,
    sage,
    archon,
    sovereign,
};

pub const RANK_SUFFIXES = [_][]const u8{
    "",          // initiate — no suffix
    "-vel",      // adept
    "-keth",     // scholar
    "-oran",     // sage
    "-arxis",    // archon
    "-solun",    // sovereign
};

// ---------------------------------------------------------------------------
// Name generation
// ---------------------------------------------------------------------------

/// Generate a single name syllable from a tradition using a seeded PRNG.
fn syllable(table: PhonemeTable, rand: std.Random) []const u8 {
    const onset  = table.onsets[rand.uintLessThan(usize, table.onsets.len)];
    _ = table.nuclei[rand.uintLessThan(usize, table.nuclei.len)]; // consumed for randomness
    const coda   = table.codas[rand.uintLessThan(usize, table.codas.len)];
    _ = onset; _ = coda;
    // Return a random onset as the syllable root (full combination assembled in generator).
    return onset;
}

/// Generate an authentic-sounding name for a given tradition and rank.
/// Returns owned string. Caller frees.
pub fn generateName(
    allocator: Allocator,
    tradition: Tradition,
    rank: Rank,
    seed: u64,
) ![]u8 {
    const table  = tableFor(tradition);
    var prng     = std.rand.DefaultPrng.init(seed);
    const rand   = prng.random();

    const onset  = table.onsets[rand.uintLessThan(usize, table.onsets.len)];
    const nucleus = table.nuclei[rand.uintLessThan(usize, table.nuclei.len)];
    const coda   = table.codas[rand.uintLessThan(usize, table.codas.len)];
    const suffix = RANK_SUFFIXES[@intFromEnum(rank)];

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    // Capitalise first letter.
    if (onset.len > 0) {
        const first = onset[0];
        try buf.append(if (first >= 'a' and first <= 'z') first - 32 else first);
        try buf.appendSlice(onset[1..]);
    }
    try buf.appendSlice(nucleus);
    try buf.appendSlice(coda);
    try buf.appendSlice(suffix);
    return try buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "generateName greek initiate" {
    const allocator = std.testing.allocator;
    const name = try generateName(allocator, .greek, .initiate, 42);
    defer allocator.free(name);
    try std.testing.expect(name.len > 0);
    // First char should be uppercase.
    try std.testing.expect(name[0] >= 'A' and name[0] <= 'Z');
}

test "generateName rank suffix" {
    const allocator = std.testing.allocator;
    const name = try generateName(allocator, .latin, .sovereign, 7);
    defer allocator.free(name);
    try std.testing.expect(std.mem.endsWith(u8, name, "-solun"));
}
