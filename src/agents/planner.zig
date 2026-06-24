const std = @import("std");
const Session    = @import("../infer/session.zig").Session;
const ToolCall   = @import("tool.zig").ToolCall;

/// A single step in an agent plan.
pub const PlanStep = struct {
    thought: []u8,   // reasoning trace
    action:  ?ToolCall, // null = final answer step
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PlanStep) void {
        self.allocator.free(self.thought);
    }
};

/// Parse a tool call from a model output line.
/// Expected format: TOOL: <name> INPUT: <json>
fn parseToolCall(line: []const u8) ?ToolCall {
    const tool_prefix  = "TOOL: ";
    const input_prefix = " INPUT: ";
    if (!std.mem.startsWith(u8, line, tool_prefix)) return null;
    const rest = line[tool_prefix.len..];
    const sep  = std.mem.indexOf(u8, rest, input_prefix) orelse return null;
    return .{
        .name  = rest[0..sep],
        .input = rest[sep + input_prefix.len ..],
    };
}

/// ReAct-style planner: interleave Thought / Action / Observation steps.
/// Returns an ArrayList of PlanSteps. Caller owns and must deinit each step.
pub const Planner = struct {
    session:    *Session,
    max_steps:  usize,
    allocator:  std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        session: *Session,
        max_steps: usize,
    ) Planner {
        return .{ .session = session, .max_steps = max_steps, .allocator = allocator };
    }

    /// Generate a plan for a task. Returns steps until FINAL ANSWER or max_steps.
    pub fn plan(
        self: *Planner,
        task: []const u8,
        tool_descriptions: []const u8,
    ) !std.ArrayList(PlanStep) {
        var steps = std.ArrayList(PlanStep).init(self.allocator);
        errdefer {
            for (steps.items) |*s| s.deinit();
            steps.deinit();
        }

        var prompt_buf = std.ArrayList(u8).init(self.allocator);
        defer prompt_buf.deinit();

        try prompt_buf.writer().print(
            "You are an agent. Available tools:\n{s}\n\nTask: {s}\n\nThought:",
            .{ tool_descriptions, task },
        );

        var step: usize = 0;
        while (step < self.max_steps) : (step += 1) {
            const eos = [_]u32{ self.session.tokenizer.vocab.eos_id };
            const output = try self.session.generate(prompt_buf.items, 256, &eos);
            defer self.allocator.free(output);

            const thought = try self.allocator.dupe(u8, output);
            var tool_call: ?ToolCall = null;

            // Scan output lines for a TOOL: directive.
            var lines = std.mem.splitScalar(u8, output, '\n');
            while (lines.next()) |line| {
                if (parseToolCall(line)) |tc| { tool_call = tc; break; }
            }

            try steps.append(.{
                .thought   = thought,
                .action    = tool_call,
                .allocator = self.allocator,
            });

            // If no tool call, assume final answer.
            if (tool_call == null) break;

            // Append output to prompt for next step.
            try prompt_buf.appendSlice(output);
            try prompt_buf.appendSlice("\nObservation: <tool result>\nThought:");
        }

        return steps;
    }
};
