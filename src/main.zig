//! main.zig — Arcis engine entry point
//! Phase 12 — Refinement & Delivery
//! Usage: arcis [--tier forma|figura|visio] [--port 8080]

const std = @import("std");
const ArcisSession = @import("dashboard/arcis_session.zig").ArcisSession;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI args.
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var tier: []const u8 = "visio";
    var port: u16 = 8080;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--tier") and i + 1 < args.len) {
            i += 1;
            tier = args[i];
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = try std.fmt.parseInt(u16, args[i], 10);
        }
    }

    std.log.info("Arcis starting — tier: {s}  port: {d}", .{ tier, port });

    var session = try ArcisSession.init(allocator, tier);
    defer session.deinit();

    std.log.info("ArcisSession ready. Subsystems wired: infer, rag, agents, media, workflow, ontology, library, naming, search, api, dashboard.", .{});
    std.log.info("API server would listen on 127.0.0.1:{d} — TCP loop stubbed for Phase 12 integration.", .{port});

    // TODO: wire session.tier router to server.zig TCP accept loop.
}
