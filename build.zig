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

    const asm_module = b.createModule(.{
        .root_source_file = b.path("src/asm.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "figment", .module = core }},
    });
    asm_module.addAnonymousImport("self-test.asm", .{ .root_source_file = b.path("programs/self-test.asm") });
    asm_module.addAnonymousImport("demo.asm", .{ .root_source_file = b.path("programs/demo.asm") });
    const asm_exe = b.addExecutable(.{ .name = "figment-asm", .root_module = asm_module });
    b.installArtifact(asm_exe);
    const asm_tests = b.addTest(.{ .root_module = asm_module, .filters = test_filters });

    const run_module = b.createModule(.{
        .root_source_file = b.path("src/run.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "figment", .module = core }},
    });
    run_module.addAnonymousImport("SPEC.md", .{ .root_source_file = b.path("SPEC.md") });
    const run_exe = b.addExecutable(.{ .name = "figment-run", .root_module = run_module });
    b.installArtifact(run_exe);
    const run_tests = b.addTest(.{ .root_module = run_module, .filters = test_filters });

    const assemble_self_test = b.addRunArtifact(asm_exe);
    assemble_self_test.addFileArg(b.path("programs/self-test.asm"));
    const self_test_bin = assemble_self_test.addOutputFileArg("self-test.bin");

    b.installDirectory(.{ .source_dir = b.path("web"), .install_dir = .prefix, .install_subdir = "web" });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(wasm.getEmittedBin(), .{ .custom = "web" }, "figment.wasm").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(self_test_bin, .{ .custom = "web" }, "self-test.bin").step);
    const assemble_demo = b.addRunArtifact(asm_exe);
    assemble_demo.addFileArg(b.path("programs/demo.asm"));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(assemble_demo.addOutputFileArg("demo.bin"), .{ .custom = "web" }, "demo.bin").step);

    const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", "-d" });
    serve.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "web" } });
    serve.step.dependOn(b.getInstallStep());
    b.step("serve", "Build, then serve the page at http://localhost:8000").dependOn(&serve.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(wasm_tests).step);
    test_step.dependOn(&b.addRunArtifact(asm_tests).step);
    test_step.dependOn(&b.addRunArtifact(run_tests).step);

    const bad_source = b.addWriteFiles().add("bad.asm", "HLT\nNOP\n");
    const asm_cli = b.addRunArtifact(asm_exe);
    asm_cli.addFileArg(bad_source);
    _ = asm_cli.addOutputFileArg("bad.bin");
    asm_cli.expectStdErrMatch("bad.asm:2: unknown instruction\n");
    asm_cli.expectExitCode(1);
    test_step.dependOn(&asm_cli.step);

    const run_self_test = b.addRunArtifact(run_exe);
    run_self_test.addFileArg(self_test_bin);
    var green: std.ArrayList(u8) = .empty;
    for (0..64) |_| {
        green.appendSlice(b.allocator, "\x1b[38;2;60;196;90;48;2;60;196;90m") catch @panic("OOM");
        for (0..128) |_| green.appendSlice(b.allocator, "▀") catch @panic("OOM");
        green.appendSlice(b.allocator, "\x1b[0m\n") catch @panic("OOM");
    }
    run_self_test.expectStdOutEqual(green.items);
    run_self_test.expectExitCode(0);
    test_step.dependOn(&run_self_test.step);

    const faulting = b.addWriteFiles().add("fault.bin", "\x10\x10\x01\xFF");
    const run_fault = b.addRunArtifact(run_exe);
    run_fault.addFileArg(faulting);
    run_fault.expectStdErrMatch("faulted at 0x0003\n");
    run_fault.expectExitCode(1);
    test_step.dependOn(&run_fault.step);

    const zeros = b.allocator.alloc(u8, 0x8000 + 1) catch @panic("OOM");
    @memset(zeros, 0);
    const run_full = b.addRunArtifact(run_exe);
    run_full.addFileArg(b.addWriteFiles().add("full.bin", zeros[0..0x8000]));
    run_full.expectExitCode(0);
    test_step.dependOn(&run_full.step);
    const too_big = b.addRunArtifact(run_exe);
    too_big.addFileArg(b.addWriteFiles().add("big.bin", zeros));
    too_big.expectStdErrMatch("big.bin: the program does not fit in memory\n");
    too_big.expectExitCode(1);
    test_step.dependOn(&too_big.step);
}
