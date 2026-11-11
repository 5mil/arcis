//! Melos MIDI output helpers.
//! Convert SymbolicPiece / MidiNote arrays into a simple MIDI file or stream.
//! Multi-track aware.

const std = @import("std");
const types = @import("types.zig");

/// Write a minimal Type-1 MIDI file (multi-track) to a buffer.
/// Returns owned slice. Suitable for download or external synth.
pub fn toMidiFile(
    allocator: std.mem.Allocator,
    piece: *const types.SymbolicPiece,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // Header chunk
    try buf.appendSlice("MThd");
    try writeU32(&buf, 6); // header length
    try writeU16(&buf, 1); // format 1
    try writeU16(&buf, @intCast(piece.tracks.len));
    try writeU16(&buf, piece.ticks_per_quarter);

    // One track chunk per MidiTrack
    for (piece.tracks) |track| {
        try buf.appendSlice("MTrk");
        const len_pos = buf.items.len;
        try writeU32(&buf, 0); // placeholder

        var last_tick: u32 = 0;
        for (track.events) |note| {
            // delta time
            try writeVarLen(&buf, note.start_tick - last_tick);
            // note on
            try buf.append(0x90 | note.channel);
            try buf.append(note.pitch);
            try buf.append(note.velocity);
            last_tick = note.start_tick;

            // note off
            try writeVarLen(&buf, note.duration_ticks);
            try buf.append(0x80 | note.channel);
            try buf.append(note.pitch);
            try buf.append(0);
            last_tick += note.duration_ticks;
        }
        // end of track
        try writeVarLen(&buf, 0);
        try buf.appendSlice(&[_]u8{ 0xFF, 0x2F, 0x00 });

        // patch length
        const track_len: u32 = @intCast(buf.items.len - len_pos - 4);
        std.mem.writeInt(u32, buf.items[len_pos..][0..4], track_len, .big);
    }

    return buf.toOwnedSlice();
}

fn writeU32(buf: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try buf.appendSlice(&b);
}
fn writeU16(buf: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try buf.appendSlice(&b);
}
fn writeVarLen(buf: *std.ArrayList(u8), v: u32) !void {
    // simplified: single byte for demo values < 128
    try buf.append(@intCast(v & 0x7F));
}

// ---------------------------------------------------------------------------
// Multi-track live step sketch:
// Generate one bar for melody + bass + drums in parallel and merge.
// See generate.zig / live.zig for extension points.
//
