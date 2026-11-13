//! Aggregates all Melos unit tests: `zig build test-melos` or
//! `zig test src/media/melos/melos_tests.zig`.
test {
    _ = @import("theory.zig");
    _ = @import("generate.zig");
    _ = @import("live.zig");
    _ = @import("api.zig");

}
