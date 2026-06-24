/// Engine-wide runtime configuration.
pub const Config = struct {
    version: []const u8,
    threads: usize,
    device: Device,
    log_level: LogLevel,

    pub const Device = enum {
        cpu,
        cuda,
        metal,
        vulkan,
    };

    pub const LogLevel = enum {
        silent,
        err,
        warn,
        info,
        debug,
    };

    pub fn default() Config {
        return .{
            .version = "0.1.0",
            .threads = 4,
            .device = .cpu,
            .log_level = .info,
        };
    }
};
