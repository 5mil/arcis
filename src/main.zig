//! main.zig — Arcis engine entry point
//! Usage: arcis [--tier forma|figura|visio] [--port 8080] [--model path/to/model.gguf]

const std = @import("std");
const ArcisSession   = @import("dashboard/arcis_session.zig").ArcisSession;
const Server         = @import("api/server.zig").Server;
const ServerConfig   = @import("api/server.zig").ServerConfig;
const TierDispatcher = @import("api/tier.zig").TierDispatcher;
const performers    = @import("media/melos/performers.zig");

const HOUSE_GGUF = "models/gguf/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "performers")) {
        try performers.runCli(allocator, args[2..]);
        return;
    }

    var tier: []const u8 = "visio";
    var port: u16 = 9090;
    var model_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--tier") and i + 1 < args.len) {
            i += 1; tier = args[i];
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1; port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--model") and i + 1 < args.len) {
            i += 1; model_path = args[i];
        }
    }

    if (model_path == null) {
        if (std.fs.cwd().access(HOUSE_GGUF, .{})) {
            model_path = HOUSE_GGUF;
        } else |_| {}
    }

    std.log.info("Arcis starting — tier: {s}  port: {d}", .{ tier, port });

    var session = try ArcisSession.init(allocator, tier);
    defer session.deinit();

    if (model_path) |path| {
        std.log.info("loading model: {s}", .{path});
        session.loadModel(path) catch |err| {
            std.log.err("failed to load model: {}", .{err});
        };
    } else {
        std.log.info("no model; run tools/pull_gguf.sh then restart", .{});
    }

    performers.loadDefault() catch |err| {
        std.log.err("performer file: {}", .{err});
    };
    if (performers.hasAccounts()) {
        std.log.info("performer accounts loaded: {d}", .{performers.accountCount()});
    } else {
        std.log.info("no performer file; run performers.sh init", .{});
    }

    var dispatcher = TierDispatcher.init(allocator, &session, tier);
    var srv = Server.init(allocator, &dispatcher, .{ .port = port, .host = "127.0.0.1" });

    std.log.info("Routes: / /health /infer /rag /search /api/melos/*", .{});
    try srv.serve();
}
