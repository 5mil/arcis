//! build.zig — Arcis engine build script
//! Compatible with Zig 0.14 and 0.15+
//! Uses root_module so it works after the 0.15 removal of the deprecated
//! root_source_file field on ExecutableOptions / TestOptions.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------------------
    // Shared modules
    // ---------------------------------------------------------------------------
    const common_mod = b.createModule(.{
        .root_source_file = b.path("src/common/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const import_mod = b.createModule(.{
        .root_source_file = b.path("src/import/importer.zig"),
        .target = target,
        .optimize = optimize,
    });
    import_mod.addImport("common", common_mod);

    const ontology_mod = b.createModule(.{
        .root_source_file = b.path("src/ontology/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ontology_mod.addImport("common", common_mod);

    const library_mod = b.createModule(.{
        .root_source_file = b.path("src/library/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    library_mod.addImport("common", common_mod);
    library_mod.addImport("import", import_mod);

    const naming_mod = b.createModule(.{
        .root_source_file = b.path("src/naming/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    naming_mod.addImport("common", common_mod);

    const rag_mod = b.createModule(.{
        .root_source_file = b.path("src/rag/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const search_mod = b.createModule(.{
        .root_source_file = b.path("src/search/index.zig"),
        .target = target,
        .optimize = optimize,
    });
    search_mod.addImport("common", common_mod);
    search_mod.addImport("rag", rag_mod);

    const workflow_mod = b.createModule(.{
        .root_source_file = b.path("src/workflow/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const infer_mod = b.createModule(.{
        .root_source_file = b.path("src/infer/engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Dashboard module (used by api)
    const dashboard_mod = b.createModule(.{
        .root_source_file = b.path("src/dashboard/arcis_session.zig"),
        .target = target,
        .optimize = optimize,
    });
    dashboard_mod.addImport("common", common_mod);
    dashboard_mod.addImport("ontology", ontology_mod);
    dashboard_mod.addImport("library", library_mod);
    dashboard_mod.addImport("naming", naming_mod);
    dashboard_mod.addImport("search", search_mod);
    dashboard_mod.addImport("workflow", workflow_mod);
    dashboard_mod.addImport("infer", infer_mod);

    const api_mod = b.createModule(.{
        .root_source_file = b.path("src/api/tier.zig"),
        .target = target,
        .optimize = optimize,
    });
    api_mod.addImport("dashboard", dashboard_mod);
    api_mod.addImport("naming", naming_mod);
    api_mod.addImport("workflow", workflow_mod);

    // ---------------------------------------------------------------------------
    // Main executable (root_module style — works on 0.14 and 0.15+)
    // ---------------------------------------------------------------------------
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "arcis",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run step: zig build run -- [args]
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the Arcis engine");
    run_step.dependOn(&run_cmd.step);

    // ---------------------------------------------------------------------------
    // Test suite — attach only the modules each test actually needs
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
        const test_mod = b.createModule(.{
            .root_source_file = b.path(sys.path),
            .target = target,
            .optimize = optimize,
        });

        // Always available
        test_mod.addImport("common", common_mod);

        // Only attach modules that the subsystem actually imports
        if (std.mem.eql(u8, sys.name, "library") or std.mem.eql(u8, sys.name, "dashboard")) {
            test_mod.addImport("import", import_mod);
        }
        if (std.mem.eql(u8, sys.name, "dashboard")) {
            test_mod.addImport("ontology", ontology_mod);
            test_mod.addImport("library", library_mod);
            test_mod.addImport("naming", naming_mod);
            test_mod.addImport("search", search_mod);
            test_mod.addImport("workflow", workflow_mod);
            test_mod.addImport("infer", infer_mod);
            test_mod.addImport("api", api_mod);
        }
        if (std.mem.eql(u8, sys.name, "api")) {
            test_mod.addImport("dashboard", dashboard_mod);
            test_mod.addImport("naming", naming_mod);
            test_mod.addImport("workflow", workflow_mod);
        }
        if (std.mem.eql(u8, sys.name, "search")) {
            test_mod.addImport("rag", rag_mod);
        }

        const t = b.addTest(.{
            .name = sys.name,
            .root_module = test_mod,
            .filter = test_filter,
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
