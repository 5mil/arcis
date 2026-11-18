//! root.zig — re-export for the "media" named module

pub const melos = struct {
    pub const handleGenerate = @import("melos/api.zig").handleGenerate;
    pub const handleAnalyze = @import("melos/api.zig").handleAnalyze;
    pub const handleLiveStep = @import("melos/api.zig").handleLiveStep;
    pub const handleLiveModulate = @import("melos/api.zig").handleLiveModulate;
    pub const initLive = @import("melos/api.zig").initLive;
};
