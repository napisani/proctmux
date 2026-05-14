const std = @import("std");
const cli = @import("../cli/root.zig");
const commands = @import("../commands/root.zig");
const config = @import("../config/root.zig");
const ipc = @import("../ipc/root.zig");
const modes = @import("../modes/root.zig");
const terminal = @import("../terminal/root.zig");
const test_ansi = @import("../test_support/ansi.zig");
const test_io = @import("../test_support/io.zig");
const unified = @import("../unified/root.zig");
const version = @import("../version.zig");

pub const Input = modes.io.Input;
pub const Output = modes.io.Output;

const FileInput = modes.io.FileInput;
const EmptyInput = modes.io.EmptyInput;

pub fn exitCodeForError(err: anyerror) u8 {
    return switch (err) {
        error.HelpRequested => 0,
        error.DeprecatedFlag,
        error.UnknownFlag,
        error.MissingFlagValue,
        error.InvalidBool,
        error.ClientUnifiedConflict,
        error.MultipleUnifiedOrientations,
        => 2,
        else => 1,
    };
}

pub fn shouldPrintGenericError(err: anyerror) bool {
    return switch (err) {
        error.DeprecatedFlag,
        error.HelpRequested,
        error.ClientUnifiedConflict,
        error.MultipleUnifiedOrientations,
        error.UnknownFlag,
        error.MissingFlagValue,
        error.InvalidBool,
        error.MissingName,
        error.UnknownSignalCommand,
        error.CommandFailed,
        => false,
        else => true,
    };
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, output: Output) !void {
    var stdin = std.fs.File.stdin();
    var terminal_mode = terminal.mode.Mode.enterIfNeeded(argsNeedRawTerminal(args), stdin.handle);
    defer terminal_mode.restore();
    try runWithInput(allocator, args, FileInput.reader(&stdin), output);
}

pub fn runWithInput(allocator: std.mem.Allocator, args: []const []const u8, input: Input, output: Output) !void {
    try runInDirWithInput(allocator, std.fs.cwd(), args, input, output);
}

pub fn runInDir(allocator: std.mem.Allocator, dir: std.fs.Dir, args: []const []const u8, output: Output) !void {
    try runInDirWithInput(allocator, dir, args, EmptyInput.reader(), output);
}

pub fn runInDirWithInput(allocator: std.mem.Allocator, dir: std.fs.Dir, args: []const []const u8, input: Input, output: Output) !void {
    var stopped = std.atomic.Value(bool).init(false);
    try runInDirUntilStoppedWithInput(allocator, dir, args, input, output, &stopped);
}

pub fn runInDirUntilStopped(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    args: []const []const u8,
    output: Output,
    stopped: *std.atomic.Value(bool),
) !void {
    try runInDirUntilStoppedWithInput(allocator, dir, args, EmptyInput.reader(), output, stopped);
}

pub fn runInDirUntilStoppedWithInput(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    args: []const []const u8,
    input: Input,
    output: Output,
    stopped: *std.atomic.Value(bool),
) !void {
    const parsed = cli.parse(args) catch |err| switch (err) {
        error.DeprecatedFlag => {
            if (cli.deprecatedFlagMessage(args)) |message| {
                try output.writeAll(message);
                try output.writeAll("\n");
            }
            return err;
        },
        error.HelpRequested => {
            try output.writeAll(cli.usage_text);
            return;
        },
        error.ClientUnifiedConflict => {
            try output.writeAll("--client cannot be combined with unified mode options\n");
            return err;
        },
        error.MultipleUnifiedOrientations => {
            try output.writeAll("multiple unified orientation flags specified\n");
            return err;
        },
        error.UnknownFlag => {
            if (cli.unknownFlagName(args)) |name| {
                try output.writeAll("flag provided but not defined: -");
                try output.writeAll(name);
                try output.writeAll("\n");
                try output.writeAll(cli.usage_text);
            }
            return err;
        },
        error.MissingFlagValue => {
            if (cli.missingValueFlagName(args)) |name| {
                try output.writeAll("flag needs an argument: -");
                try output.writeAll(name);
                try output.writeAll("\n");
                try output.writeAll(cli.usage_text);
            }
            return err;
        },
        error.InvalidBool => {
            if (cli.invalidBoolFlag(args)) |diagnostic| {
                try output.writeAll("invalid boolean value \"");
                try output.writeAll(diagnostic.value);
                try output.writeAll("\" for -");
                try output.writeAll(diagnostic.name);
                try output.writeAll(": parse error\n");
                try output.writeAll(cli.usage_text);
            }
            return err;
        },
        else => return err,
    };
    if (parsed.version_requested) {
        try output.writeAll(version.banner());
        try output.writeAll("\n");
        return;
    }
    if (std.mem.eql(u8, parsed.subcommand, "config-init")) {
        const path = try commands.config_init.runInDir(dir, parsed.args);
        try output.writeAll("Created starter configuration at ");
        try output.writeAll(path);
        try output.writeAll("\n");
        return;
    }

    if (isSignalCommand(parsed.subcommand)) {
        try modes.signal.run(
            allocator,
            dir,
            parsed.config_file,
            parsed.subcommand,
            parsed.args,
            output,
        );
        return;
    }

    if (parsed.mode == .client and !parsed.unified) {
        try modes.client.run(allocator, dir, parsed.config_file, input, output);
        return;
    }

    if (parsed.unified) {
        try unified.runtime.run(allocator, dir, args, parsed.config_file, parsed.unified_orientation, input, output);
        return;
    }

    if (parsed.mode == .primary and
        !parsed.unified and
        std.mem.eql(u8, parsed.subcommand, "start"))
    {
        try modes.primary.runUntilStopped(allocator, dir, parsed.config_file, input, output, stopped);
        return;
    }

    try output.writeAll(version.banner());
    try output.writeAll("\n");
}

fn isSignalCommand(subcommand: []const u8) bool {
    return std.mem.startsWith(u8, subcommand, "signal-");
}

fn argsNeedRawTerminal(args: []const []const u8) bool {
    const parsed = cli.parse(args) catch return false;
    if (parsed.version_requested) return false;
    if (isSignalCommand(parsed.subcommand)) return false;
    if (std.mem.eql(u8, parsed.subcommand, "config-init")) return false;
    return parsed.unified or parsed.mode == .client or std.mem.eql(u8, parsed.subcommand, "start");
}

test "app routes config-init and prints created path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDir(std.testing.allocator, tmp.dir, &.{"config-init"}, test_io.TestOutput.writer(&out));

    try tmp.dir.access("proctmux.yaml", .{});
    try std.testing.expectEqualStrings("Created starter configuration at proctmux.yaml\n", out.items);
}

test "app prints deprecated unified toggle migration guidance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.DeprecatedFlag, runInDir(std.testing.allocator, tmp.dir, &.{"--unified-toggle"}, test_io.TestOutput.writer(&out)));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "--unified-toggle has been removed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "hide_process_list_when_unfocused: true") != null);
}

test "deprecated CLI flag exits like legacy behavior without generic error text" {
    try std.testing.expectEqual(@as(u8, 2), exitCodeForError(error.DeprecatedFlag));
    try std.testing.expect(!shouldPrintGenericError(error.DeprecatedFlag));
}

test "app prints legacy-compatible client unified conflict message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.ClientUnifiedConflict, runInDir(std.testing.allocator, tmp.dir, &.{ "--client", "--unified" }, test_io.TestOutput.writer(&out)));
    try std.testing.expectEqual(@as(u8, 2), exitCodeForError(error.ClientUnifiedConflict));
    try std.testing.expect(!shouldPrintGenericError(error.ClientUnifiedConflict));
    try std.testing.expectEqualStrings("--client cannot be combined with unified mode options\n", out.items);
}

test "app prints legacy-compatible multiple unified orientation message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.MultipleUnifiedOrientations, runInDir(std.testing.allocator, tmp.dir, &.{ "--unified-left", "--unified-right" }, test_io.TestOutput.writer(&out)));
    try std.testing.expectEqual(@as(u8, 2), exitCodeForError(error.MultipleUnifiedOrientations));
    try std.testing.expect(!shouldPrintGenericError(error.MultipleUnifiedOrientations));
    try std.testing.expectEqualStrings("multiple unified orientation flags specified\n", out.items);
}

test "app prints legacy-compatible unknown flag diagnostic and usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.UnknownFlag, runInDir(std.testing.allocator, tmp.dir, &.{"--bad"}, test_io.TestOutput.writer(&out)));
    try std.testing.expectEqual(@as(u8, 2), exitCodeForError(error.UnknownFlag));
    try std.testing.expect(!shouldPrintGenericError(error.UnknownFlag));
    try std.testing.expect(std.mem.startsWith(u8, out.items, "flag provided but not defined: -bad\nUsage: proctmux [options] [command]"));
}

test "app prints legacy-compatible missing flag value diagnostic and usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.MissingFlagValue, runInDir(std.testing.allocator, tmp.dir, &.{"-f"}, test_io.TestOutput.writer(&out)));
    try std.testing.expectEqual(@as(u8, 2), exitCodeForError(error.MissingFlagValue));
    try std.testing.expect(!shouldPrintGenericError(error.MissingFlagValue));
    try std.testing.expect(std.mem.startsWith(u8, out.items, "flag needs an argument: -f\nUsage: proctmux [options] [command]"));
}

test "app prints legacy-compatible invalid bool diagnostic and usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(error.InvalidBool, runInDir(std.testing.allocator, tmp.dir, &.{"--client=nope"}, test_io.TestOutput.writer(&out)));
    try std.testing.expectEqual(@as(u8, 2), exitCodeForError(error.InvalidBool));
    try std.testing.expect(!shouldPrintGenericError(error.InvalidBool));
    try std.testing.expect(std.mem.startsWith(u8, out.items, "invalid boolean value \"nope\" for -client: parse error\nUsage: proctmux [options] [command]"));
}

test "app suppresses generic stderr for signal command failures like legacy behavior" {
    try std.testing.expectEqual(@as(u8, 1), exitCodeForError(error.MissingName));
    try std.testing.expectEqual(@as(u8, 1), exitCodeForError(error.UnknownSignalCommand));
    try std.testing.expectEqual(@as(u8, 1), exitCodeForError(error.CommandFailed));
    try std.testing.expect(!shouldPrintGenericError(error.MissingName));
    try std.testing.expect(!shouldPrintGenericError(error.UnknownSignalCommand));
    try std.testing.expect(!shouldPrintGenericError(error.CommandFailed));
}

test "app prints legacy-compatible CLI help for help flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDir(std.testing.allocator, tmp.dir, &.{"--help"}, test_io.TestOutput.writer(&out));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "Usage: proctmux [options] [command]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Options:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "-client") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "-unified-right") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Modes:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "--unified-bottom") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "signal-stop-running") != null);
}

test "app prints version for version flag without starting TUI" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDir(std.testing.allocator, tmp.dir, &.{"--version"}, test_io.TestOutput.writer(&out));

    try std.testing.expect(out.items.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), out.items[out.items.len - 1]);
    try std.testing.expectEqualStrings(version.banner(), out.items[0 .. out.items.len - 1]);
}

test "app routes signal-list through config-derived socket" {
    const tmp_path = "/tmp/proctmux-zig-app-signal-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = "proctmux.yaml", .data = "{}\n" });

    const real_config_path = try dir.realpathAlloc(std.testing.allocator, "proctmux.yaml");
    defer std.testing.allocator.free(real_config_path);

    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    try config.defaults.apply(&cfg, std.testing.allocator);
    cfg.file_path = real_config_path;

    const socket_path = try ipc.socket.createPathForConfig(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(socket_path);
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    const address = try std.net.Address.initUnix(socket_path);
    var server = try address.listen(.{});
    defer server.deinit();

    var capture = OneShotCapture{};
    var responded = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, runProbeTolerantSignalListResponseServer, .{ &server, &capture, &responded });

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    const result = runInDir(std.testing.allocator, dir, &.{"signal-list"}, test_io.TestOutput.writer(&out));
    unblockServer(socket_path);
    unblockServer(socket_path);
    thread.join();
    try result;

    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\trunning\nworker\tstopped\n", out.items);
    if (capture.err) |err| return err;
    try std.testing.expectEqualStrings(
        "{\"type\":\"command\",\"request_id\":\"1\",\"action\":\"list\"}\n",
        capture.requestLine(),
    );
}

test "app primary mode serves signal-list from loaded config" {
    const tmp_path = "/tmp/proctmux-zig-app-primary-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    try waitForSocketFile(socket_path);

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDir(std.testing.allocator, dir, &.{"signal-list"}, test_io.TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    if (run_state.err) |err| return err;

    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\tstopped\n", out.items);
}

test "app client mode connects to primary and renders process list" {
    const tmp_path = "/tmp/proctmux-zig-app-client-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDir(std.testing.allocator, dir, &.{"--client"}, test_io.TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try std.testing.expect(std.mem.indexOf(u8, out.items, "api") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, version.banner()) == null);
}

test "app client mode refreshes render after process command broadcast" {
    const tmp_path = "/tmp/proctmux-zig-app-client-refresh-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var input = test_io.BytesInput{ .data = "js" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDirWithInput(std.testing.allocator, dir, &.{"--client"}, test_io.BytesInput.reader(&input), test_io.TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try test_ansi.expectContainsPlain(std.testing.allocator, out.items, "■ api");
    try test_ansi.expectContainsPlain(std.testing.allocator, out.items, "● api");
}

test "app client mode keypress redraws avoid repeated full-screen clears" {
    const tmp_path = "/tmp/proctmux-zig-app-client-repaint-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\  worker:
        \\    shell: "sleep 5"
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var input = test_io.BytesInput{ .data = "jkjkq" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDirWithInput(std.testing.allocator, dir, &.{"--client"}, test_io.BytesInput.reader(&input), test_io.TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try std.testing.expect(std.mem.indexOf(u8, out.items, "worker") != null);
    try std.testing.expect(countOccurrences(out.items, "\x1b[?25l") >= 1);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(out.items, "\x1b[?25h"));
    try std.testing.expect(countOccurrences(out.items, "\x1b[2J") <= 1);
}

test "app client mode maps down arrow to process navigation" {
    const tmp_path = "/tmp/proctmux-zig-app-client-arrow-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var input = test_io.BytesInput{ .data = "\x1b[B" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDirWithInput(std.testing.allocator, dir, &.{"--client"}, test_io.BytesInput.reader(&input), test_io.TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try test_ansi.expectContainsPlain(std.testing.allocator, out.items, "▶ ■ api");
}

test "app client mode maps up arrow to process navigation" {
    const tmp_path = "/tmp/proctmux-zig-app-client-up-arrow-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\  worker:
        \\    shell: "sleep 5"
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var input = test_io.BytesInput{ .data = "j\x1b[A" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDirWithInput(std.testing.allocator, dir, &.{"--client"}, test_io.BytesInput.reader(&input), test_io.TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try test_ansi.expectContainsPlain(std.testing.allocator, out.items, "▶ ■ worker");
}

test "app client mode accepts printable filter input" {
    const tmp_path = "/tmp/proctmux-zig-app-client-filter-input-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\  worker:
        \\    shell: "sleep 5"
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var input = test_io.BytesInput{ .data = "/api\nq" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDirWithInput(std.testing.allocator, dir, &.{"--client"}, test_io.BytesInput.reader(&input), test_io.TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try std.testing.expect(std.mem.indexOf(u8, out.items, "Filter: api") != null);
    try test_ansi.expectContainsPlain(std.testing.allocator, out.items, "▶ ■ api");
}

test "app client mode renders command failure message and keeps running" {
    const tmp_path = "/tmp/proctmux-zig-app-client-command-failure-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = "proctmux.yaml", .data = "{}\n" });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var input = test_io.BytesInput{ .data = "sq" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDirWithInput(std.testing.allocator, dir, &.{"--client"}, test_io.BytesInput.reader(&input), test_io.TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try std.testing.expect(std.mem.indexOf(u8, out.items, "No matching processes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Messages:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "- no process selected") != null);
}

test "app client mode quit stops running primary processes" {
    const tmp_path = "/tmp/proctmux-zig-app-client-quit-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\    autostart: true
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    var thread_joined = false;
    errdefer {
        if (!thread_joined) {
            stopped.store(true, .seq_cst);
            unblockServer(socket_path);
            thread.join();
        }
    }
    try waitForSocketFile(socket_path);

    var input = test_io.BytesInput{ .data = "q" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runInDirWithInput(std.testing.allocator, dir, &.{"--client"}, test_io.BytesInput.reader(&input), test_io.TestOutput.writer(&out));

    out.clearRetainingCapacity();
    try runInDir(std.testing.allocator, dir, &.{"signal-list"}, test_io.TestOutput.writer(&out));

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;

    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\tstopped\n", out.items);
}

test "app primary mode serves signal start list and stop commands" {
    const tmp_path = "/tmp/proctmux-zig-app-primary-control-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var run_state = AppPrimaryRun{
        .dir_path = tmp_path,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryApp, .{&run_state});
    errdefer {
        stopped.store(true, .seq_cst);
        unblockServer(socket_path);
        thread.join();
    }
    try waitForSocketFile(socket_path);

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDir(std.testing.allocator, dir, &.{ "signal-start", "api" }, test_io.TestOutput.writer(&out));
    try std.testing.expectEqualStrings("", out.items);

    try runInDir(std.testing.allocator, dir, &.{"signal-list"}, test_io.TestOutput.writer(&out));
    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\trunning\n", out.items);

    out.clearRetainingCapacity();
    try runInDir(std.testing.allocator, dir, &.{ "signal-stop", "api" }, test_io.TestOutput.writer(&out));
    try std.testing.expectEqualStrings("", out.items);

    try runInDir(std.testing.allocator, dir, &.{"signal-list"}, test_io.TestOutput.writer(&out));
    try std.testing.expectEqualStrings("NAME\tSTATUS\napi\tstopped\n", out.items);

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    if (run_state.err) |err| return err;
}

test "app primary mode forwards stdin to selected running process" {
    const tmp_path = "/tmp/proctmux-zig-app-primary-stdin-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    const got_path = tmp_path ++ "/got.txt";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteFileAbsolute(got_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    cwd: "/tmp/proctmux-zig-app-primary-stdin-test"
        \\    shell: |
        \\      IFS= read line; printf '%s' "$line" > got.txt
        \\    autostart: true
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var loaded = try config.load.loadFileInDir(std.testing.allocator, dir, "proctmux.yaml");
    defer loaded.deinit();
    const socket_path = try ipc.socket.pathForConfig(std.testing.allocator, &loaded.config);
    defer std.testing.allocator.free(socket_path);

    var stopped = std.atomic.Value(bool).init(false);
    var input = test_io.BlockingInput{ .data = "hello\n" };
    var run_state = AppPrimaryInputRun{
        .dir_path = tmp_path,
        .input = &input,
        .stopped = &stopped,
    };
    const thread = try std.Thread.spawn(.{}, runPrimaryAppWithInput, .{&run_state});
    var thread_joined = false;
    errdefer {
        input.release();
        stopped.store(true, .seq_cst);
        unblockServer(socket_path);
        if (!thread_joined) thread.join();
    }
    try waitForSocketFile(socket_path);

    try runInDir(std.testing.allocator, dir, &.{ "signal-switch", "api" }, test_io.NullOutput.writer());
    input.release();
    try test_io.waitForFileContains(dir, "got.txt", "hello");

    stopped.store(true, .seq_cst);
    unblockServer(socket_path);
    thread.join();
    thread_joined = true;
    if (run_state.err) |err| return err;
}

test "app unified mode renders process list and exits on quit" {
    const tmp_path = "/tmp/proctmux-zig-app-unified-render-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var input = test_io.BytesInput{ .data = "q" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDirWithInput(std.testing.allocator, dir, &.{"--unified"}, test_io.BytesInput.reader(&input), test_io.TestOutput.writer(&out));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "api") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Client | server") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, version.banner()) == null);
}

test "app unified mode hides process list when server focused and configured" {
    const tmp_path = "/tmp/proctmux-zig-app-unified-hide-list-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\layout:
        \\  hide_process_list_when_unfocused: true
        \\procs:
        \\  api:
        \\    shell: "sleep 5"
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var input = test_io.BytesInput{ .data = "\x17\x17q" };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDirWithInput(std.testing.allocator, dir, &.{"--unified"}, test_io.BytesInput.reader(&input), test_io.TestOutput.writer(&out));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "process list hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Client | server") != null);
}

test "app unified mode forwards server-focused input to selected process" {
    const tmp_path = "/tmp/proctmux-zig-app-unified-stdin-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    const got_path = tmp_path ++ "/got.txt";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteFileAbsolute(got_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    cwd: "/tmp/proctmux-zig-app-unified-stdin-test"
        \\    shell: |
        \\      IFS= read line; printf '%s' "$line" > got.txt; sleep 5
        \\    autostart: true
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var input = test_io.FileGateInput{
        .dir = &dir,
        .path = "got.txt",
        .needle = "hello",
        .first = "j\x17hello\n",
        .second = "\x17q",
    };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDirWithInput(std.testing.allocator, dir, &.{"--unified"}, test_io.FileGateInput.reader(&input), test_io.TestOutput.writer(&out));

    try test_ansi.expectContainsPlain(std.testing.allocator, out.items, "▶ ● api");
    try std.testing.expect(std.mem.indexOf(u8, out.items, "client | Server") != null);
    try test_io.waitForFileContains(dir, "got.txt", "hello");
}

test "app unified mode process output redraws avoid repeated full-screen clears" {
    const tmp_path = "/tmp/proctmux-zig-app-unified-repaint-test";
    const config_path = tmp_path ++ "/proctmux.yaml";
    const done_path = tmp_path ++ "/done.txt";
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteFileAbsolute(done_path) catch {};
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_path, .{});
    defer dir.close();
    try dir.writeFile(.{
        .sub_path = "proctmux.yaml",
        .data =
        \\procs:
        \\  api:
        \\    cwd: "/tmp/proctmux-zig-app-unified-repaint-test"
        \\    shell: |
        \\      i=1
        \\      while [ "$i" -le 5 ]; do
        \\        printf 'LINE_%s\n' "$i"
        \\        i=$((i + 1))
        \\        sleep 0.1
        \\      done
        \\      printf done > done.txt
        \\      sleep 5
        \\    autostart: true
        \\    stop_timeout_ms: 500
        \\
        ,
    });

    var input = test_io.FileGateInput{
        .dir = &dir,
        .path = "done.txt",
        .needle = "done",
        .first = "j",
        .second = "q",
    };
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();

    try runInDirWithInput(std.testing.allocator, dir, &.{"--unified"}, test_io.FileGateInput.reader(&input), test_io.TestOutput.writer(&out));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "LINE_") != null);
    try std.testing.expect(countOccurrences(out.items, "\x1b[?25l") >= 1);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(out.items, "\x1b[?25h"));
    try std.testing.expect(countOccurrences(out.items, "\x1b[2J") <= 1);
}

const AppPrimaryRun = struct {
    dir_path: []const u8,
    stopped: *std.atomic.Value(bool),
    err: ?anyerror = null,
};

const AppPrimaryInputRun = struct {
    dir_path: []const u8,
    input: *test_io.BlockingInput,
    stopped: *std.atomic.Value(bool),
    err: ?anyerror = null,
};

fn runPrimaryApp(state: *AppPrimaryRun) void {
    var dir = std.fs.openDirAbsolute(state.dir_path, .{}) catch |err| {
        state.err = err;
        return;
    };
    defer dir.close();

    runInDirUntilStoppedWithInput(std.testing.allocator, dir, &.{}, EmptyInput.reader(), test_io.NullOutput.writer(), state.stopped) catch |err| {
        state.err = err;
    };
}

fn runPrimaryAppWithInput(state: *AppPrimaryInputRun) void {
    var dir = std.fs.openDirAbsolute(state.dir_path, .{}) catch |err| {
        state.err = err;
        return;
    };
    defer dir.close();

    runInDirUntilStoppedWithInput(std.testing.allocator, dir, &.{}, test_io.BlockingInput.reader(state.input), test_io.NullOutput.writer(), state.stopped) catch |err| {
        state.err = err;
    };
}

const OneShotCapture = struct {
    request: [512]u8 = undefined,
    request_len: usize = 0,
    response: []const u8 =
        "{\"type\":\"response\",\"request_id\":\"1\",\"success\":true,\"process_list\":[{\"index\":1,\"name\":\"api\",\"running\":true},{\"index\":2,\"name\":\"worker\",\"running\":false}]}\n",
    err: ?anyerror = null,

    fn requestLine(self: *const OneShotCapture) []const u8 {
        return self.request[0..self.request_len];
    }
};

fn runProbeTolerantSignalListResponseServer(
    server: *std.net.Server,
    capture: *OneShotCapture,
    responded: *std.atomic.Value(bool),
) void {
    const first = server.accept() catch |err| {
        capture.err = err;
        return;
    };
    const first_thread = std.Thread.spawn(.{}, handleMaybeSignalCommand, .{ first, capture, responded }) catch |err| {
        capture.err = err;
        first.stream.close();
        return;
    };

    const second = server.accept() catch |err| {
        capture.err = err;
        first_thread.join();
        return;
    };
    handleMaybeSignalCommand(second, capture, responded);
    first_thread.join();

    if (!responded.load(.seq_cst)) capture.err = error.TestExpectedCommandConnection;
}

fn handleMaybeSignalCommand(
    conn: std.net.Server.Connection,
    capture: *OneShotCapture,
    responded: *std.atomic.Value(bool),
) void {
    defer conn.stream.close();

    var request: [512]u8 = undefined;
    const len = conn.stream.read(&request) catch |err| {
        capture.err = err;
        return;
    };
    if (len == 0) return;
    if (responded.swap(true, .seq_cst)) return;

    @memcpy(capture.request[0..len], request[0..len]);
    capture.request_len = len;
    conn.stream.writeAll(capture.response) catch |err| {
        capture.err = err;
        return;
    };
}

fn unblockServer(path: []const u8) void {
    var stream = std.net.connectUnixSocket(path) catch return;
    stream.close();
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;

    var count: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        count += 1;
        rest = rest[index + needle.len ..];
    }
    return count;
}

fn waitForSocketFile(path: []const u8) !void {
    try ipc.socket.waitPath(path, 30 * 1000, 100);
}
