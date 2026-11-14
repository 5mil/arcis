//! Melos effects pedals.
//! Audience designs and submits pedals; the performer reviews, approves and
//! activates them; active pedals shape the notes of the instrument they target.
//! Fixed-capacity, allocation-free board (all text is copied into inline buffers).

const std = @import("std");
const types = @import("types.zig");
const instruments = @import("instruments.zig");

pub const MAX_PEDALS = 32;

pub const Status = enum { submitted, approved, rejected, active };

pub const Pedal = struct {
    id: u32 = 0,
    name: [32]u8 = undefined,
    name_len: u8 = 0,
    author: [24]u8 = undefined,
    author_len: u8 = 0,
    instrument: [16]u8 = undefined,
    instrument_len: u8 = 0,
    description: [96]u8 = undefined,
    description_len: u8 = 0,

    pitch_shift: i8 = 0, // semitones
    velocity_scale: f32 = 1.0,
    density_scale: f32 = 1.0, // < 1 thins weak-position notes
    reverb_amount: f32 = 0.0, // lengthens notes up to +50%
    delay_ticks: u32 = 0, // adds a soft echo note after this many ticks
    status: Status = .submitted,

    pub fn nameS(self: *const Pedal) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn authorS(self: *const Pedal) []const u8 {
        return self.author[0..self.author_len];
    }
    pub fn instrumentS(self: *const Pedal) []const u8 {
        return self.instrument[0..self.instrument_len];
    }
    pub fn descriptionS(self: *const Pedal) []const u8 {
        return self.description[0..self.description_len];
    }
};

pub const Submission = struct {
    name: []const u8,
    author: []const u8 = "crowd",
    instrument: []const u8,
    description: []const u8 = "",
    pitch_shift: i32 = 0,
    velocity_scale: f32 = 1.0,
    density_scale: f32 = 1.0,
    reverb_amount: f32 = 0.0,
    delay_ticks: u32 = 0,
};

pub const SubmitError = error{ BadName, UnknownInstrument, BoardFull };

fn copyClean(dst: []u8, src: []const u8) u8 {
    var n: usize = 0;
    for (src) |ch| {
        if (n >= dst.len) break;
        if (ch < 0x20 or ch == 0x7f) continue; // drop control characters
        dst[n] = ch;
        n += 1;
    }
    return @intCast(n);
}

/// Channel (track) an instrument is rendered on: 0 melody, 1 pad, 2 bass; null = not rendered.
pub fn channelFor(instrument: []const u8) ?u4 {
    const eq = std.mem.eql;
    if (eq(u8, instrument, "Piano") or eq(u8, instrument, "Flute") or eq(u8, instrument, "Synth Lead") or eq(u8, instrument, "Electric Piano")) return 0;
    if (eq(u8, instrument, "Strings") or eq(u8, instrument, "Synth Pad") or eq(u8, instrument, "Choir")) return 1;
    if (eq(u8, instrument, "Bass") or eq(u8, instrument, "Guitar")) return 2;
    return null;
}

pub const PedalBoard = struct {
    items: [MAX_PEDALS]Pedal = undefined,
    count: usize = 0,
    next_id: u32 = 1,

    pub fn submit(self: *PedalBoard, s: Submission) SubmitError!u32 {
        if (std.mem.trim(u8, s.name, " ").len == 0) return error.BadName;
        if (instruments.findByName(s.instrument) == null) return error.UnknownInstrument;
        if (self.count >= MAX_PEDALS) return error.BoardFull;
        var p = Pedal{ .id = self.next_id };
        p.name_len = copyClean(&p.name, s.name);
        if (p.name_len == 0) return error.BadName;
        p.author_len = copyClean(&p.author, s.author);
        p.instrument_len = copyClean(&p.instrument, s.instrument);
        p.description_len = copyClean(&p.description, s.description);
        p.pitch_shift = @intCast(std.math.clamp(s.pitch_shift, -12, 12));
        p.velocity_scale = std.math.clamp(s.velocity_scale, 0.25, 2.0);
        p.density_scale = std.math.clamp(s.density_scale, 0.25, 2.0);
        p.reverb_amount = std.math.clamp(s.reverb_amount, 0.0, 1.0);
        p.delay_ticks = @min(s.delay_ticks, 960);
        self.items[self.count] = p;
        self.count += 1;
        self.next_id += 1;
        return p.id;
    }

    pub fn find(self: *PedalBoard, id: u32) ?*Pedal {
        for (self.items[0..self.count]) |*p| if (p.id == id) return p;
        return null;
    }

    pub const Transition = enum { approve, activate, reject, deactivate };

    /// Performer state machine: submitted -> approved -> active (and back).
    pub fn transition(self: *PedalBoard, id: u32, t: Transition) bool {
        const p = self.find(id) orelse return false;
        switch (t) {
            .approve => if (p.status == .submitted or p.status == .rejected) {
                p.status = .approved;
            } else return false,
            .activate => if (p.status == .approved) {
                p.status = .active;
            } else return false, // must be approved first
            .reject => if (p.status != .active) {
                p.status = .rejected;
            } else return false,
            .deactivate => if (p.status == .active) {
                p.status = .approved;
            } else return false,
        }
        return true;
    }

    pub fn activeCount(self: *const PedalBoard) usize {
        var n: usize = 0;
        for (self.items[0..self.count]) |p| if (p.status == .active) {
            n += 1;
        };
        return n;
    }

    /// Apply every active pedal to `notes` (in place, may append echoes while
    /// capacity allows). `beat_grid_pos` of a note = ((start % bar)+60)/120.
    /// Returns the new note count.
    pub fn applyActive(self: *const PedalBoard, notes: []types.MidiNote, n_in: usize) usize {
        var n = n_in;
        for (self.items[0..self.count]) |p| {
            if (p.status != .active) continue;
            const ch = channelFor(p.instrumentS()) orelse continue;
            const original = n;
            var i: usize = 0;
            while (i < original) : (i += 1) {
                var nt = &notes[i];
                if (nt.channel != ch) continue;
                const shifted = @as(i32, nt.pitch) + p.pitch_shift;
                nt.pitch = @intCast(std.math.clamp(shifted, 0, 127));
                nt.velocity = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(nt.velocity)) * p.velocity_scale, 1, 127));
                if (p.reverb_amount > 0) {
                    const extra: u32 = @intFromFloat(@as(f32, @floatFromInt(nt.duration_ticks)) * 0.5 * p.reverb_amount);
                    nt.duration_ticks += extra;
                }
                if (p.delay_ticks > 0 and n < notes.len) {
                    notes[n] = nt.*;
                    notes[n].start_tick += p.delay_ticks;
                    notes[n].velocity = @max(nt.velocity / 2, 1);
                    n += 1;
                }
            }
            if (p.density_scale < 1.0) {
                // keep downbeat-ish notes; thin weaker ones by an integer stride
                const keep_every: usize = @max(2, @as(usize, @intFromFloat(@round(1.0 / @max(1.0 - p.density_scale, 0.05)))));
                var w: usize = 0;
                var k: usize = 0;
                var seen: usize = 0;
                while (k < n) : (k += 1) {
                    const strong = ((notes[k].start_tick % 1920) + 60) / 120 % 4 == 0;
                    var keep = true;
                    if (notes[k].channel == ch and !strong) {
                        seen += 1;
                        keep = seen % keep_every != 0;
                    }
                    if (keep) {
                        notes[w] = notes[k];
                        w += 1;
                    }
                }
                n = w;
            }
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mk(ch: u4, pitch: u8, start: u32) types.MidiNote {
    return .{ .pitch = pitch, .velocity = 80, .start_tick = start, .duration_ticks = 240, .channel = ch };
}

test "pedal submit validates and sanitises" {
    var b = PedalBoard{};
    try testing.expectError(error.BadName, b.submit(.{ .name = "  ", .instrument = "Piano" }));
    try testing.expectError(error.UnknownInstrument, b.submit(.{ .name = "x", .instrument = "Kazoo" }));
    const id = try b.submit(.{ .name = "Warm\nChorus", .instrument = "Piano", .pitch_shift = 99, .velocity_scale = 9, .delay_ticks = 99999 });
    const p = b.find(id).?;
    try testing.expectEqualStrings("WarmChorus", p.nameS());
    try testing.expectEqual(@as(i8, 12), p.pitch_shift);
    try testing.expectEqual(@as(f32, 2.0), p.velocity_scale);
    try testing.expectEqual(@as(u32, 960), p.delay_ticks);
    try testing.expectEqual(Status.submitted, p.status);
}

test "board is bounded" {
    var b = PedalBoard{};
    for (0..MAX_PEDALS) |_| _ = try b.submit(.{ .name = "p", .instrument = "Bass" });
    try testing.expectError(error.BoardFull, b.submit(.{ .name = "p", .instrument = "Bass" }));
}

test "performer approval state machine" {
    var b = PedalBoard{};
    const id = try b.submit(.{ .name = "p", .instrument = "Piano" });
    try testing.expect(!b.transition(id, .activate)); // not approved yet
    try testing.expect(b.transition(id, .approve));
    try testing.expect(b.transition(id, .activate));
    try testing.expect(!b.transition(id, .reject)); // active cannot be rejected directly
    try testing.expect(b.transition(id, .deactivate));
    try testing.expect(b.transition(id, .reject));
    try testing.expect(!b.transition(999, .approve));
}

test "only active pedals change notes, and only on their instrument's channel" {
    var b = PedalBoard{};
    const id = try b.submit(.{ .name = "up", .instrument = "Piano", .pitch_shift = 5, .velocity_scale = 0.5, .delay_ticks = 480 });
    var notes: [16]types.MidiNote = undefined;
    notes[0] = mk(0, 60, 0);
    notes[1] = mk(2, 40, 0);
    var n = b.applyActive(&notes, 2);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u8, 60), notes[0].pitch); // submitted: no effect
    _ = b.transition(id, .approve);
    n = b.applyActive(&notes, 2);
    try testing.expectEqual(@as(u8, 60), notes[0].pitch); // approved: still no effect
    _ = b.transition(id, .activate);
    n = b.applyActive(&notes, 2);
    try testing.expectEqual(@as(usize, 3), n); // echo added
    try testing.expectEqual(@as(u8, 65), notes[0].pitch);
    try testing.expectEqual(@as(u8, 40), notes[1].pitch); // other channel untouched
    try testing.expectEqual(@as(u8, 40), notes[0].velocity);
    try testing.expectEqual(@as(u32, 480), notes[2].start_tick);
}
