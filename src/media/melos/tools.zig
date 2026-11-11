//! Melos tools — step 2 of the Melos roadmap.
//! Registers music-specific tools into Arcis’s existing ToolRegistry.
//! Compatible with Agent / Orchestrator / Planner (src/agents/).

const std = @import("std");
const Tool = @import("../../agents/tool.zig").Tool;
const ToolRegistry = @import("../../agents/tool.zig").ToolRegistry;
const types = @import("types.zig");

/// Placeholder handler: echo the input for now.
/// Later these will call real stem, TTS, or symbolic generators.
fn echoHandler(allocator: std.mem.Allocator, input: []const u8) anyerror![]u8 {
    return try std.fmt.allocPrint(allocator, "melos_echo: {s}", .{input});
}

fn stubGenerateHandler(allocator: std.mem.Allocator, input: []const u8) anyerror![]u8 {
    // Future: parse attributes or text, return SymbolicPiece JSON.
    return try std.fmt.allocPrint(allocator, "melos_generate_stub: received {d} bytes", .{input.len});
}

fn stubAnalyzeHandler(allocator: std.mem.Allocator, input: []const u8) anyerror![]u8 {
    return try std.fmt.allocPrint(allocator, "melos_analyze_stub: {s}", .{input});
}

/// Register the core Melos toolset into an existing Arcis ToolRegistry.
pub fn registerMelosTools(registry: *ToolRegistry) !void {
    try registry.register(.{ 
        .name = "melos.generate", 
        .description = "Generate a SymbolicPiece from text or MusicAttributes. Input: JSON attributes or prompt.",
        .handler = stubGenerateHandler,
    });
    try registry.register(.{ 
        .name = "melos.analyze", 
        .description = "Analyze a SymbolicPiece or MIDI for key, emotion, structure, density.",
        .handler = stubAnalyzeHandler,
    });
    try registry.register(.{ 
        .name = "melos.echo", 
        .description = "Echo tool for testing Melos registration.",
        .handler = echoHandler,
    });
}

/// Suggested AgentRole for a music copilot.
pub const melos_agent_role = struct {
    pub const name = "melos";
    pub const description = "Music understanding and generation agent. Uses melos.* tools plus media stems/TTS/ASR.";
    pub const allowed_tools = "melos.generate,melos.analyze,melos.echo";
};

// ---------------------------------------------------------------------------
// Usage sketch (inside Arcis session / orchestrator init):
//
// var registry = ToolRegistry.init(allocator);
// try melos.tools.registerMelosTools(&registry);
// const role = AgentRole{
//     .name = melos.tools.melos_agent_role.name,
//     .description = melos.tools.melos_agent_role.description,
//     .allowed_tools = melos.tools.melos_agent_role.allowed_tools,
// };
// var agent = Agent.init(allocator, role, session, &registry, 8);
// const answer = try agent.run("Generate a calm A-minor verse with piano and soft drums");
//
