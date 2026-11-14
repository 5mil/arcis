//! Melos core types — step 1 of the Melos roadmap.
//! Symbolic music interfaces and data formats for Arcis.
//! Pure Zig, no model dependencies. Agents and generators will consume these.

const std = @import("std");

/// MIDI note event (channel-agnostic simplified form).
pub const MidiNote = struct {
    pitch: u8,          // 0–127
    velocity: u8,       // 0–127
    start_tick: u32,    // absolute ticks from start of track
    duration_ticks: u32,
    channel: u4 = 0,
};

/// Control change or other non-note event (optional for later).
pub const MidiEvent = union(enum) {
    note: MidiNote,
    // Future: cc, pitch_bend, program_change, tempo, time_sig, key_sig, …
};

/// Single MIDI track.
pub const MidiTrack = struct {
    name: []const u8,
    role: TrackRole,
    program: u8 = 0,    // GM program number
    events: []MidiNote, // simplified to notes for v1
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MidiTrack) void {
        self.allocator.free(self.events);
        self.allocator.free(self.name);
    }
};

/// Semantic role of a track (used by generation and mixing).
pub const TrackRole = enum {
    melody,
    bass,
    drums,
    accompaniment,
    pad,
    lead,
    rhythm,
    other,
};

/// Musical attributes that condition generation or describe a piece.
/// Inspired by MuseCoco attribute set.
pub const MusicAttributes = struct {
    key: ?Key = null,
    tempo_bpm: ?f32 = null,
    time_signature: ?TimeSignature = null,
    emotion: ?Emotion = null,
    genre: ?[]const u8 = null,
    density: ?f32 = null,          // 0.0–1.0 note density
    pitch_range: ?PitchRange = null,
    instruments: ?[]const u8 = null,
    bars: ?u16 = null,

    pub fn deinit(self: *MusicAttributes, allocator: std.mem.Allocator) void {
        if (self.genre) |g| allocator.free(g);
        if (self.instruments) |i| allocator.free(i);
    }
};

pub const Key = struct {
    tonic: u4,          // 0=C … 11=B
    mode: Mode,
};

pub const Mode = enum { major, minor, dorian, mixolydian, lydian, phrygian };

pub const TimeSignature = struct {
    numerator: u8,
    denominator: u8,
};

pub const Emotion = enum {
    happy,
    sad,
    energetic,
    calm,
    dark,
    bright,
    tense,
    relaxed,
};

pub const PitchRange = struct {
    low: u8,
    high: u8,
};

/// Mask indicating which tracks/roles should be generated or kept.
pub const TrackMask = struct {
    roles: std.EnumSet(TrackRole),
    // or explicit track indices later
};

/// Lyric–melody alignment unit (for lyric-conditioned generation).
pub const LyricAlignment = struct {
    text: []const u8,
    start_tick: u32,
    duration_ticks: u32,
    notes: []const u32, // indices into a MidiTrack.events
};

/// Complete symbolic piece.
pub const SymbolicPiece = struct {
    attributes: MusicAttributes,
    tracks: []MidiTrack,
    alignments: []LyricAlignment = &.{},
    ticks_per_quarter: u16 = 480,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SymbolicPiece) void {
        for (self.tracks) |*t| t.deinit();
        self.allocator.free(self.tracks);
        self.attributes.deinit(self.allocator);
        // alignments ownership TBD
    }
};

/// Tool interface that Melos agents will call.
/// Implementations can be native Zig, external process, or GGUF model later.
pub const MelosTool = struct {
    name: []const u8,
    description: []const u8,
    /// Function pointer or vtable entry for execution.
    execute: *const fn (ctx: *anyopaque, input: MelosToolInput) anyerror!MelosToolOutput,
    context: *anyopaque,
};

pub const MelosToolInput = union(enum) {
    text: []const u8,
    attributes: MusicAttributes,
    piece: SymbolicPiece,
    audio_path: []const u8, // for stem/ASR tools
};

pub const MelosToolOutput = union(enum) {
    piece: SymbolicPiece,
    attributes: MusicAttributes,
    text: []const u8,
    audio_paths: [][]const u8,
};

/// Registry helper (minimal; real one lives in Arcis agents).
pub const MelosToolRegistry = struct {
    tools: std.StringHashMap(MelosTool),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MelosToolRegistry {
        return .{
            .tools = std.StringHashMap(MelosTool).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MelosToolRegistry) void {
        self.tools.deinit();
    }

    pub fn register(self: *MelosToolRegistry, tool: MelosTool) !void {
        try self.tools.put(tool.name, tool);
    }
};

// ---------------------------------------------------------------------------
// Example usage sketch (not compiled)
// ---------------------------------------------------------------------------
//
// var piece = SymbolicPiece{ ... };
// var mask = TrackMask{ .roles = .{ .melody = true, .bass = true } };
// const result = try generate_from_attributes(attributes, mask);
//
