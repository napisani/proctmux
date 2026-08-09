//! Build script for the shipped proctmux binary and test target.
//! The build keeps vendored terminal dependencies wired in one place so runtime modules can import narrow adapters instead of knowing build-system details.

const std = @import("std");

const TerminalArtifact = enum {
    ghostty,
    lib,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option(
        []const u8,
        "version",
        "Version string embedded in the proctmux binary",
    ) orelse "1.0.0-dev";
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Filter for Zig unit tests",
    ) orelse &[0][]const u8{};

    const yaml_dep = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });
    const ghostty_vt = addGhosttyVtModule(b, target, optimize);
    const version_options = addVersionOptions(b, version);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_module.addImport("yaml", yaml_dep.module("yaml"));
    exe_module.addImport("ghostty-vt", ghostty_vt);
    exe_module.addOptions("version_options", version_options);

    const exe = b.addExecutable(.{
        .name = "proctmux",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run proctmux");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addImport("yaml", yaml_dep.module("yaml"));
    test_module.addImport("ghostty-vt", ghostty_vt);
    test_module.addOptions("version_options", version_options);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
        .filters = test_filters,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn addVersionOptions(b: *std.Build, version: []const u8) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    return options;
}

fn addGhosttyVtModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const uucode_build_config = b.path("third_party/libghostty-vt/src/build/uucode_config.zig");
    const uucode_tables = b.dependency("uucode", .{
        .build_config_path = uucode_build_config,
    }).namedLazyPath("tables.zig");

    const target_uucode = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .tables_path = uucode_tables,
        .build_config_path = uucode_build_config,
    }).module("uucode");
    const terminal_options = addGhosttyTerminalOptions(b);
    const build_options = addGhosttyBuildOptions(b);

    const vt = b.createModule(.{
        .root_source_file = b.path("third_party/libghostty-vt/src/proctmux_vt.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vt.addImport("uucode", target_uucode);
    vt.addOptions("terminal_options", terminal_options);
    vt.addOptions("build_options", build_options);
    vt.addAnonymousImport("unicode_tables", .{
        .root_source_file = b.path("third_party/libghostty-vt/src/unicode/generated/ghostty-unicode-props.zig"),
    });
    vt.addAnonymousImport("symbols_tables", .{
        .root_source_file = b.path("third_party/libghostty-vt/src/unicode/generated/ghostty-unicode-symbols.zig"),
    });
    return vt;
}

fn addGhosttyTerminalOptions(b: *std.Build) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(TerminalArtifact, "artifact", .lib);
    options.addOption(bool, "c_abi", false);
    options.addOption(bool, "oniguruma", false);
    options.addOption(bool, "simd", false);
    options.addOption(bool, "slow_runtime_safety", false);
    options.addOption(bool, "kitty_graphics", false);
    options.addOption(bool, "tmux_control_mode", false);
    options.addOption([]const u8, "version_string", "1.0.0");
    options.addOption(usize, "version_major", 1);
    options.addOption(usize, "version_minor", 0);
    options.addOption(usize, "version_patch", 0);
    options.addOption(?[]const u8, "version_pre", null);
    options.addOption(?[]const u8, "version_build", null);
    return options;
}

fn addGhosttyBuildOptions(b: *std.Build) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "simd", false);
    return options;
}
