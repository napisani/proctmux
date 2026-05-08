const std = @import("std");

const default_rows: u16 = 24;
const default_cols: u16 = 80;

extern "c" fn forkpty(
    amaster: *c_int,
    name: ?[*:0]u8,
    termp: ?*const std.posix.termios,
    winp: ?*const std.posix.winsize,
) std.posix.pid_t;

pub const Spawned = struct {
    pid: std.posix.pid_t,
    master: std.fs.File,
};

pub fn spawn(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env_map: *const std.process.EnvMap,
    cwd: []const u8,
    rows: u16,
    cols: u16,
) !Spawned {
    if (argv.len == 0) return error.InvalidProcessConfig;

    var resolved_argv = try ResolvedArgv.init(allocator, argv, env_map);
    defer resolved_argv.deinit();

    var argv_z = try ArgvZ.init(allocator, resolved_argv.argv);
    defer argv_z.deinit();

    var env_arena = std.heap.ArenaAllocator.init(allocator);
    defer env_arena.deinit();
    const envp = try std.process.createEnvironFromMap(env_arena.allocator(), env_map, .{});

    const cwd_z = if (cwd.len > 0) try allocator.dupeZ(u8, cwd) else null;
    defer if (cwd_z) |path| allocator.free(path);

    var size: std.posix.winsize = .{
        .row = if (rows > 0) rows else default_rows,
        .col = if (cols > 0) cols else default_cols,
        .xpixel = 0,
        .ypixel = 0,
    };

    var master_fd: c_int = -1;
    const pid = forkpty(&master_fd, null, null, &size);
    if (pid < 0) return error.PtySpawnFailed;

    if (pid == 0) {
        if (cwd_z) |path| std.posix.chdirZ(path.ptr) catch std.process.exit(127);
        std.posix.execveZ(argv_z.ptrs[0].?, argv_z.ptrs.ptr, envp.ptr) catch {};
        std.process.exit(127);
    }

    return .{
        .pid = pid,
        .master = .{ .handle = @intCast(master_fd) },
    };
}

pub fn configureRawMode(file: std.fs.File) !void {
    var raw = try std.posix.tcgetattr(file.handle);

    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.IXON = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;

    try std.posix.tcsetattr(file.handle, .FLUSH, raw);
}

const ResolvedArgv = struct {
    allocator: std.mem.Allocator,
    argv: [][]const u8,
    resolved_path: ?[]const u8,

    fn init(
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        env_map: *const std.process.EnvMap,
    ) !ResolvedArgv {
        const resolved_path = try resolveExecutable(allocator, argv[0], env_map);
        errdefer if (resolved_path) |path| allocator.free(path);

        const resolved_argv = try allocator.alloc([]const u8, argv.len);
        errdefer allocator.free(resolved_argv);
        @memcpy(resolved_argv, argv);
        if (resolved_path) |path| resolved_argv[0] = path;

        return .{
            .allocator = allocator,
            .argv = resolved_argv,
            .resolved_path = resolved_path,
        };
    }

    fn deinit(self: *ResolvedArgv) void {
        if (self.resolved_path) |path| self.allocator.free(path);
        self.allocator.free(self.argv);
    }
};

fn resolveExecutable(
    allocator: std.mem.Allocator,
    executable: []const u8,
    env_map: *const std.process.EnvMap,
) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, executable, '/') != null) return null;

    const path_value = env_map.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    var path_it = std.mem.splitScalar(u8, path_value, ':');
    while (path_it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, executable });
        errdefer allocator.free(candidate);
        std.fs.cwd().access(candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(candidate);
                continue;
            },
            else => {
                allocator.free(candidate);
                return err;
            },
        };
        return candidate;
    }

    return null;
}

const ArgvZ = struct {
    allocator: std.mem.Allocator,
    strings: [][:0]u8,
    ptrs: [:null]?[*:0]const u8,

    fn init(allocator: std.mem.Allocator, argv: []const []const u8) !ArgvZ {
        const strings = try allocator.alloc([:0]u8, argv.len);
        errdefer allocator.free(strings);

        const ptrs = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
        errdefer allocator.free(ptrs);

        var initialized: usize = 0;
        errdefer {
            for (strings[0..initialized]) |arg| allocator.free(arg);
        }

        for (argv, 0..) |arg, index| {
            strings[index] = try allocator.dupeZ(u8, arg);
            initialized += 1;
            ptrs[index] = strings[index].ptr;
        }

        return .{
            .allocator = allocator,
            .strings = strings,
            .ptrs = ptrs,
        };
    }

    fn deinit(self: *ArgvZ) void {
        for (self.strings) |arg| self.allocator.free(arg);
        self.allocator.free(self.strings);
        self.allocator.free(self.ptrs);
    }
};
