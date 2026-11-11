//! Melos effects pedals.
//! Audience can design and submit pedals; performer reviews and applies them.
//! Pedals modulate MIDI notes or attributes for a specific instrument.

const std = @import("std");
const types = @import("types.zig");
const instruments = @import("instruments.zig");

/// A user-designed effects pedal.
pub const Pedal = struct {
    id: []const u8,
    name: []const u8,
    author: []const u8,              // crowd member / session id
    target_instrument: []const u8,   // instrument name
    description: []const u8,

    /// Modulation parameters (interpreted by the engine).
    pitch_shift: i8 = 0,             // semitones
    velocity_scale: f32 = 1.0,
    density_scale: f32 = 1.0,
    filter_cutoff: ?f32 = null,      // 0.0–1.0 hint
    reverb_amount: f32 = 0.0,
    delay_ticks: u32 = 0,

    status: Status = .submitted,
    allocator: std.mem.Allocator,

    pub const Status = enum { submitted, approved, rejected, active };

    pub fn deinit(self: *Pedal) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.author);
        self.allocator.free(self.target_instrument);
        self.allocator.free(self.description);
    }
};

/// In-memory pedal board for a live session.
pub const PedalBoard = struct {
    pedals: std.ArrayList(Pedal),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PedalBoard {
        return .{ .pedals = std.ArrayList(Pedal).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *PedalBoard) void {
        for (self.pedals.items) |*p| p.deinit();
        self.pedals.deinit();
    }

    pub fn submit(self: *PedalBoard, pedal: Pedal) !void {
        try self.pedals.append(pedal);
    }

    pub fn approve(self: *PedalBoard, id: []const u8) void {
        for (self.pedals.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) {
                p.status = .approved;
                return;
            }
        }
    }

    pub fn activate(self: *PedalBoard, id: []const u8) void {
        for (self.pedals.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) {
                p.status = .active;
                return;
            }
        }
    }

    /// Apply all active pedals that target a given instrument to a note list.
    pub fn applyActive(
        self: *const PedalBoard,
        instrument_name: []const u8,
        notes: []types.MidiNote,
    ) void {
        for (self.pedals.items) |p| {
            if (p.status != .active) continue;
            if (!std.mem.eql(u8, p.target_instrument, instrument_name)) continue;
            for (notes) |*n| {
                const shifted = @as(i16, n.pitch) + p.pitch_shift;
                n.pitch = @intCast(std.math.clamp(shifted, 0, 127));
                n.velocity = @intCast(std.math.clamp(
                    @as(f32, @floatFromInt(n.velocity)) * p.velocity_scale,
                    1,
                    127,
                ));
                // delay / reverb would be expanded into extra notes in a fuller implementation
            }
        }
    }
};

// ---------------------------------------------------------------------------
// API sketch:
// POST /api/melos/pedals/submit   { name, author, instrument, description, params }
// POST /api/melos/pedals/approve  { id }
// POST /api/melos/pedals/activate { id }
// GET  /api/melos/pedals          → list
//
