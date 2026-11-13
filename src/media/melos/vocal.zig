//! Melos vocal synthesis layer.
//! Supports premium MIDI+lyrics workflows that feed official purchased voicebanks
//! (VOCALOID Editor VST/AU, Synthesizer V, ACE Studio, Emvoice, etc.).
//! Does not embed or redistribute any commercial voicebanks.

const std = @import("std");
const types = @import("types.zig");

/// Phoneme with timing (X-SAMPA style or engine-specific).
pub const Phoneme = struct {
    symbol: []const u8,
    start_tick: u32,
    duration_ticks: u32,
    stress: f32 = 0.5,
};

/// Expression parameters that map to official vocal engines where possible.
pub const VocalExpression = struct {
    breath: f32 = 0.0,       // 0.0–1.0
    tension: f32 = 0.5,
    power: f32 = 0.6,
    falsetto: f32 = 0.0,
    energy: f32 = 0.5,
    vibrato_depth: f32 = 0.3,
    vibrato_rate: f32 = 5.0,
    formant_shift: f32 = 0.0, // semitones
};

/// A monophonic vocal track ready for official engines.
pub const VocalTrack = struct {
    name: []const u8,
    language: []const u8 = "en", // en, ja, zh, etc.
    notes: []types.MidiNote,
    phonemes: []Phoneme = &.{},
    lyrics: []const u8,          // full text or timed
    expression: VocalExpression = .{},
    structure_section: ?[]const u8 = null, // [Verse], [Chorus], etc.
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VocalTrack) void {
        self.allocator.free(self.notes);
        self.allocator.free(self.phonemes);
        self.allocator.free(self.lyrics);
        if (self.structure_section) |s| self.allocator.free(s);
        self.allocator.free(self.name);
    }
};

/// Official voicebank bridge target.
pub const OfficialEngine = enum {
    vocaloid_vst,
    synthv,
    ace_studio,
    emvoice,
    other,
};

/// Export payload for official editors / VST hosts.
pub const OfficialExport = struct {
    midi_data: []u8,
    lyrics_timed: []const u8, // simple [tick] lyric or section format
    expression_json: []const u8,
    engine: OfficialEngine,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OfficialExport) void {
        self.allocator.free(self.midi_data);
        self.allocator.free(self.lyrics_timed);
        self.allocator.free(self.expression_json);
    }
};

/// Build a VocalTrack from existing Melos MIDI + lyrics.
pub fn fromMidiAndLyrics(
    allocator: std.mem.Allocator,
    notes: []const types.MidiNote,
    lyrics: []const u8,
    language: []const u8,
) !VocalTrack {
    const notes_copy = try allocator.dupe(types.MidiNote, notes);
    const lyrics_copy = try allocator.dupe(u8, lyrics);
    const lang_copy = try allocator.dupe(u8, language);
    return VocalTrack{
        .name = try allocator.dupe(u8, "vocal"),
        .language = lang_copy,
        .notes = notes_copy,
        .lyrics = lyrics_copy,
        .allocator = allocator,
    };
}

/// Generate timed lyrics string suitable for official import (simple format).
pub fn timedLyrics(allocator: std.mem.Allocator, track: *const VocalTrack) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    try buf.writer().print("[{s}]\n", .{track.structure_section orelse "Section"});
    // Naive: one lyric line per note for demo; real version splits syllables
    for (track.notes, 0..) |note, i| {
        if (i < track.lyrics.len) {
            try buf.writer().print("{d}: {c}\n", .{ note.start_tick, track.lyrics[i] });
        }
    }
    return buf.toOwnedSlice();
}

/// Prepare export for an official VST/AU or editor.
pub fn exportForOfficial(
    allocator: std.mem.Allocator,
    track: *const VocalTrack,
    engine: OfficialEngine,
    midi_bytes: []const u8,
) !OfficialExport {
    const lyrics = try timedLyrics(allocator, track);
    const expr = try std.fmt.allocPrint(allocator,
        \"{{\"breath\":{d:.2},\"tension\":{d:.2},\"power\":{d:.2},\"falsetto\":{d:.2},\"energy\":{d:.2},\"vibrato_depth\":{d:.2}}}"
    , .{
        track.expression.breath,
        track.expression.tension,
        track.expression.power,
        track.expression.falsetto,
        track.expression.energy,
        track.expression.vibrato_depth,
    });
    return OfficialExport{
        .midi_data = try allocator.dupe(u8, midi_bytes),
        .lyrics_timed = lyrics,
        .expression_json = expr,
        .engine = engine,
        .allocator = allocator,
    };
}

/// Placeholder for VST/AU host communication.
/// Real implementation would use a plugin host (e.g. via c-api or process bridge)
/// to send MIDI+lyrics into the user's licensed VOCALOID / SynthV / ACE plugin
/// and receive rendered audio.
pub fn hostOfficialPlugin(
    track: *const VocalTrack,
    engine: OfficialEngine,
) void {
    // Future: open plugin, set voicebank, send notes + phonemes + expression,
    // capture audio buffer for Melos live mix or Kick stream.
    _ = track;
    _ = engine;
    // For now the export path is the supported legal bridge.
}
