//! build.zig — Arcis engine build script
//! Phase 12 — Refinement & Delivery
//! Zig build system: one binary, all subsystems wired, tier selectable at runtime.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------------------
    // Main executable
    // ---------------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name    = "arcis",
        .root_source_file = b.path("src/main.zig"),
        .target  = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // Run step: zig build run -- [args]
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the Arcis engine");
    run_step.dependOn(&run_cmd.step);

    // ---------------------------------------------------------------------------
    // Test suite
    // ---------------------------------------------------------------------------
    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name");

    const subsystems = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "core",      .path = "src/core/tensor.zig"                    },
        .{ .name = "infer",     .path = "src/infer/session.zig"                  },
        .{ .name = "rag",       .path = "src/rag/pipeline.zig"                   },
        .{ .name = "agents",    .path = "src/agents/orchestrator.zig"            },
        .{ .name = "media",     .path = "src/media/media_session.zig"            },
        .{ .name = "workflow",  .path = "src/workflow/workflow_session.zig"      },
        .{ .name = "common",    .path = "src/common/store.zig"                   },
        .{ .name = "import",    .path = "src/import/importer.zig"               },
        .{ .name = "export",    .path = "src/export/exporter.zig"               },
        .{ .name = "ontology",  .path = "src/ontology/terminology.zig"          },
        .{ .name = "library",   .path = "src/library/viewer.zig"                },
        .{ .name = "naming",    .path = "src/naming/name_store.zig"             },
        .{ .name = "search",    .path = "src/search/query.zig"                  },
        .{ .name = "api",       .path = "src/api/tier.zig"                      },
        .{ .name = "dashboard", .path = "src/dashboard/arcis_session.zig"       },
    };

    const test_all_step = b.step("test", "Run all subsystem tests");

    inline for (subsystems) |sys| {
        const t = b.addTest(.{
            .name             = sys.name,
            .root_source_file = b.path(sys.path),
            .target           = target,
            .optimize         = optimize,
            .filter           = test_filter,
        });
        const run_t = b.addRunArtifact(t);
        test_all_step.dependOn(&run_t.step);

        // Individual step: zig build test-<name>
        const single_step = b.step(
            b.fmt("test-{s}", .{sys.name}),
            b.fmt("Test src/{s}/", .{sys.name}),
        );
        single_step.dependOn(&run_t.step);
    }

    // ---------------------------------------------------------------------------
    // Tier-specific run steps
    // ---------------------------------------------------------------------------
    inline for ([_][]const u8{ "forma", "figura", "visio" }) |tier| {
        const tier_run = b.addRunArtifact(exe);
        tier_run.step.dependOn(b.getInstallStep());
        tier_run.addArgs(&.{ "--tier", tier });
        const tier_step = b.step(
            b.fmt("run-{s}", .{tier}),
            b.fmt("Run Arcis in {s} tier", .{tier}),
        );
        tier_step.dependOn(&tier_run.step);
    }
}
