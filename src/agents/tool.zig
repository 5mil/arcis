const std = @import("std");

/// A tool call request from the planner.
pub const ToolCall = struct {
    name:   []const u8,
    input:  []const u8, // JSON-encoded arguments
};

/// A tool call result.
pub const ToolResult = struct {
    name:    []const u8,
    output:  []u8, // owned
    success: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ToolResult) void {
        self.allocator.free(self.output);
    }
};

/// Tool handler function signature.
pub const ToolFn = *const fn (
    allocator: std.mem.Allocator,
    input: []const u8,
) anyerror![]u8;

/// A registered tool.
pub const Tool = struct {
    name:        []const u8,
    description: []const u8,
    handler:     ToolFn,
};

/// Tool registry: named lookup of available tools.
pub const ToolRegistry = struct {
    tools:     std.StringHashMap(Tool),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{ .tools = std.StringHashMap(Tool).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit();
    }

    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        try self.tools.put(tool.name, tool);
    }

    /// Dispatch a tool call. Returns owned ToolResult.
    pub fn dispatch(
        self: *const ToolRegistry,
        call: ToolCall,
        allocator: std.mem.Allocator,
    ) !ToolResult {
        const tool = self.tools.get(call.name) orelse {
            const msg = try std.fmt.allocPrint(allocator, "unknown tool: {s}", .{call.name});
            return ToolResult{ .name = call.name, .output = msg, .success = false, .allocator = allocator };
        };
        const out = tool.handler(allocator, call.input) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "tool error: {}", .{err});
            return ToolResult{ .name = call.name, .output = msg, .success = false, .allocator = allocator };
        };
        return ToolResult{ .name = call.name, .output = out, .success = true, .allocator = allocator };
    }
};
