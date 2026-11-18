//! main.zig — Arcis engine entry point
//! Usage: arcis [--tier forma|figura|visio] [--port 8080] [--model path/to/model.gguf]
//! Compatible with Zig 0.16+ (main receives std.process.Init;
//! filesystem APIs live on std.Io.Dir / std.Io.File).

const std = @import("std");
const ArcisSession   = @import("dashboard").ArcisSession;
const Server         = @import("api").Server;
const ServerConfig   = @import("api").ServerConfig;
const TierDispatcher = @import("api").TierDispatcher;

const HOUSE_GGUF = "models/gguf/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_it = std.process.Args.Iterator.init(init.minimal.args);

    var tier: []const u8 = "visio";
    var port: u16 = 9090;
    var model_path: ?[]const u8 = null;

    // Skip argv[0]
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tier")) {
            if (args_it.next()) |t| tier = t;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args_it.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
        } else if (std.mem.eql(u8, arg, "--model")) {
            if (args_it.next()) |m| model_path = m;
        }
    }

    if (model_path == null) {
        // Zig 0.16: std.fs.cwd() → std.Io.Dir.cwd(); disk ops take io
        const cwd = std.Io.Dir.cwd();
        if (cwd.access(io, HOUSE_GGUF, .{})) {
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

    var dispatcher = TierDispatcher.init(allocator, &session, tier);
    var srv = Server.init(allocator, &dispatcher, .{ .port = port }, io);

    std.log.info("Routes: / /health /infer /rag /search", .{});
    try srv.serve();
}
