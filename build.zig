const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main compiler executable
    const exe = b.addExecutable(.{
        .name = "cot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the compiler");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // SSA tests (core data structures)
    const ssa_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ssa/value.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_ssa_tests = b.addRunArtifact(ssa_tests);
    const ssa_test_step = b.step("test-ssa", "Run SSA unit tests");
    ssa_test_step.dependOn(&run_ssa_tests.step);

    // Create main module for importing into tests
    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Integration tests
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/full_pipeline_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_mod.addImport("main", main_module);
    const integration_tests = b.addTest(.{ .root_module = integration_mod });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Golden tests
    const golden_mod = b.createModule(.{
        .root_source_file = b.path("test/runners/golden_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    golden_mod.addImport("main", main_module);
    const golden_tests = b.addTest(.{ .root_module = golden_mod });

    const run_golden_tests = b.addRunArtifact(golden_tests);
    const golden_test_step = b.step("test-golden", "Run golden file tests");
    golden_test_step.dependOn(&run_golden_tests.step);

    // Directive tests (test runners)
    const directive_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/runners/directive_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_directive_tests = b.addRunArtifact(directive_tests);
    const directive_test_step = b.step("test-directive", "Run directive runner tests");
    directive_test_step.dependOn(&run_directive_tests.step);

    // Diff utility tests
    const diff_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/runners/diff.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_diff_tests = b.addRunArtifact(diff_tests);

    // All tests - runs everything
    const test_all_step = b.step("test-all", "Run all tests (unit, integration, golden)");
    test_all_step.dependOn(&run_unit_tests.step);
    test_all_step.dependOn(&run_integration_tests.step);
    test_all_step.dependOn(&run_golden_tests.step);
    test_all_step.dependOn(&run_directive_tests.step);
    test_all_step.dependOn(&run_diff_tests.step);
}
