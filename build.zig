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
    if (b.args) |args| run.addArgs(args);
    run_step.dependOn(&run.step);

    const dap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_dap_tests = b.addRunArtifact(dap_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_dap_tests.step);
}
