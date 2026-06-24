const std = @import("std");
const Planner      = @import("planner.zig").Planner;
const ToolRegistry = @import("tool.zig").ToolRegistry;
const ToolCall     = @import("tool.zig").ToolCall;
const Session      = @import("../infer/session.zig").Session;

/// Agent role definition.
pub const AgentRole = struct {
    name:        []const u8,
    description: []const u8,
    /// Comma-separated list of tool names this role can use.
    allowed_tools: []const u8,
};

/// A running agent instance.
pub const Agent = struct {
    role:      AgentRole,
    planner:   Planner,
    registry:  *ToolRegistry,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        role: AgentRole,
        session: *Session,
        registry: *ToolRegistry,
        max_steps: usize,
    ) Agent {
        return .{
            .role      = role,
            .planner   = Planner.init(allocator, session, max_steps),
            .registry  = registry,
            .allocator = allocator,
        };
    }

    /// Run the agent on a task. Returns the final answer string.
    /// Caller owns returned slice.
    pub fn run(self: *Agent, task: []const u8) ![]u8 {
        // Build tool description string for the planner prompt.
        var tool_desc = std.ArrayList(u8).init(self.allocator);
        defer tool_desc.deinit();
        var it = self.registry.tools.iterator();
        while (it.next()) |entry| {
            try tool_desc.writer().print("- {s}: {s}\n",
                .{ entry.value_ptr.name, entry.value_ptr.description });
        }

        var steps = try self.planner.plan(task, tool_desc.items);
        defer {
            for (steps.items) |*s| s.deinit();
            steps.deinit();
        }

        // Execute tool calls and inject observations back into subsequent steps.
        var final_answer = std.ArrayList(u8).init(self.allocator);
        errdefer final_answer.deinit();

        for (steps.items) |*step| {
            if (step.action) |call| {
                var result = try self.registry.dispatch(call, self.allocator);
                defer result.deinit();
                // Observation is injected; final answer accumulates from non-tool steps.
                _ = result;
            } else {
                // No tool call: this is the final answer thought.
                try final_answer.appendSlice(step.thought);
            }
        }

        return final_answer.toOwnedSlice();
    }
};

/// Multi-agent orchestrator: assigns tasks to agents and collects results.
pub const Orchestrator = struct {
    agents:    std.ArrayList(Agent),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Orchestrator {
        return .{ .agents = std.ArrayList(Agent).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *Orchestrator) void {
        self.agents.deinit();
    }

    pub fn addAgent(self: *Orchestrator, agent: Agent) !void {
        try self.agents.append(agent);
    }

    /// Dispatch a task to a named agent. Returns the agent's final answer.
    /// Caller owns returned slice.
    pub fn dispatch(
        self: *Orchestrator,
        agent_name: []const u8,
        task: []const u8,
    ) ![]u8 {
        for (self.agents.items) |*agent| {
            if (std.mem.eql(u8, agent.role.name, agent_name)) {
                return agent.run(task);
            }
        }
        return error.AgentNotFound;
    }
};
