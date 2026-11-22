const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dap_module = b.addModule("dap", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "dap-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("dap", dap_module);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the manual example");
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    run_step.dependOn(&run.step);

    const dap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_dap_tests = b.addRunArtifact(dap_tests);

    // Composition lives on the other side of the import graph: `dap.zig` never
    // imports `compose.zig`, so a second test root is the only way the `test`
    // step reaches it. The duplicate compilation of `dap.zig` is harmless.
    const compose_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compose.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_compose_tests = b.addRunArtifact(compose_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_dap_tests.step);
    test_step.dependOn(&run_compose_tests.step);

    const fixture_module = b.createModule(.{
        .root_source_file = b.path("src/completion_fixture.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixture_module.addImport("dap", dap_module);

    const fixture_exe = b.addExecutable(.{
        .name = "dap-completion-fixture",
        .root_module = fixture_module,
    });

    const fixture_options = b.addOptions();
    fixture_options.addOptionPath("exe", fixture_exe.getEmittedBin());

    const completion_test_module = b.createModule(.{
        .root_source_file = b.path("src/completion_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    completion_test_module.addImport("dap", dap_module);

    const fixture_import = b.createModule(.{
        .root_source_file = b.path("src/completion_fixture.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixture_import.addImport("dap", dap_module);
    completion_test_module.addImport("completion-fixture", fixture_import);
    completion_test_module.addOptions("build_options", fixture_options);

    const completion_tests = b.addTest(.{
        .root_module = completion_test_module,
    });

    const run_completion_tests = b.addRunArtifact(completion_tests);

    const completion_test_step = b.step("completion-test", "Run shell completion integration tests");
    completion_test_step.dependOn(&run_completion_tests.step);
}
