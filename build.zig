const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains this text") orelse &.{};

    // The machine, for native tests and for any native program that wants it.
    const core = b.addModule("figment", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The module the web page loads. SPEC.md fixes it to ReleaseSmall, so -Doptimize doesn't apply.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm = b.addExecutable(.{
        .name = "figment",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "figment", .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = wasm_target,
                    .optimize = .ReleaseSmall,
                }) },
            },
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    b.installArtifact(wasm);

    const core_tests = b.addTest(.{ .root_module = core, .filters = test_filters });

    // The exports run natively under test. The built .wasm is embedded so a test can inspect it.
    const wasm_tests_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "figment", .module = core }},
    });
    wasm_tests_module.addAnonymousImport("figment.wasm", .{ .root_source_file = wasm.getEmittedBin() });
    const wasm_tests = b.addTest(.{ .root_module = wasm_tests_module, .filters = test_filters });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(wasm_tests).step);
}
