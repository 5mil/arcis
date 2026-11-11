//! Melos instrument definitions.
//! Extends TrackRole with concrete instrument presets (GM-style).

const std = @import("std");
const types = @import("types.zig");

/// Concrete instrument that can be assigned to a track.
pub const Instrument = struct {
    name: []const u8,
    role: types.TrackRole,
    gm_program: u8,          // General MIDI program number
    default_channel: u4 = 0,
};

/// Built-in instrument library (extend as needed).
pub const instruments = [_]Instrument{
    .{ .name = "Piano",        .role = .accompaniment, .gm_program = 0 },
    .{ .name = "Electric Piano", .role = .accompaniment, .gm_program = 4 },
    .{ .name = "Synth Lead",   .role = .lead,          .gm_program = 80 },
    .{ .name = "Synth Pad",    .role = .pad,           .gm_program = 88 },
    .{ .name = "Bass",         .role = .bass,          .gm_program = 33 },
    .{ .name = "Drums",        .role = .drums,         .gm_program = 0, .default_channel = 9 },
    .{ .name = "Guitar",       .role = .rhythm,        .gm_program = 25 },
    .{ .name = "Strings",      .role = .pad,           .gm_program = 48 },
    .{ .name = "Flute",        .role = .melody,        .gm_program = 73 },
    .{ .name = "Choir",        .role = .pad,           .gm_program = 52 },
};

pub fn findByName(name: []const u8) ?Instrument {
    for (instruments) |inst| {
        if (std.mem.eql(u8, inst.name, name)) return inst;
    }
    return null;
}

/// Apply an instrument to a MidiTrack (sets program + role).
pub fn applyToTrack(track: *types.MidiTrack, inst: Instrument) void {
    track.role = inst.role;
    track.program = inst.gm_program;
}
