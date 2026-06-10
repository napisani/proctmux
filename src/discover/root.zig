//! Discovery namespace and shared result types.
//! Callers depend on this module rather than individual discovery sources when merging discovered processes into Project Config.

const std = @import("std");
const config = @import("../config/root.zig");

pub const makefile = @import("makefile.zig");
pub const package_json = @import("package_json.zig");
pub const apply_mod = @import("apply.zig");

test {
    _ = makefile;
    _ = package_json;
    _ = apply_mod;
}

test "makefile discovery matches active behavior" {
    var procs = try makefile.discover(std.testing.allocator, "testdata/phase2/discovery");
    defer makefile.deinitProcessMap(std.testing.allocator, &procs);

    const build = procs.get("make:build").?;
    try std.testing.expectEqualStrings("make build", build.shell);
    try std.testing.expectEqualStrings("testdata/phase2/discovery", build.cwd);
    try std.testing.expectEqualStrings("makefile", build.categories.items[0]);

    const test_proc = procs.get("make:test").?;
    try std.testing.expectEqualStrings("make test", test_proc.shell);

    const phony = procs.get("make:.PHONY").?;
    try std.testing.expectEqualStrings("make .PHONY", phony.shell);
}

test "missing Makefile returns source not found" {
    try std.testing.expectError(error.SourceNotFound, makefile.discover(std.testing.allocator, "testdata/phase2/config"));
}

test "package json discovery detects pnpm and skips invalid script names" {
    var procs = try package_json.discover(std.testing.allocator, "testdata/phase2/discovery");
    defer makefile.deinitProcessMap(std.testing.allocator, &procs);

    const dev = procs.get("pnpm:dev").?;
    try std.testing.expectEqualStrings("testdata/phase2/discovery", dev.cwd);
    try std.testing.expectEqualStrings("pnpm", dev.categories.items[0]);
    try std.testing.expectEqualStrings("pnpm", dev.cmd.items[0]);
    try std.testing.expectEqualStrings("run", dev.cmd.items[1]);
    try std.testing.expectEqualStrings("dev", dev.cmd.items[2]);
    try std.testing.expectEqualStrings("Auto-discovered pnpm script: node server.js", dev.description);

    const build = procs.get("pnpm:build").?;
    try std.testing.expectEqualStrings("build", build.cmd.items[2]);

    try std.testing.expect(procs.get("pnpm:bad script") == null);
}

test "manager command construction matches legacy behavior" {
    const pnpm = try package_json.commandPreview(std.testing.allocator, "pnpm", "dev");
    defer std.testing.allocator.free(pnpm);
    const yarn = try package_json.commandPreview(std.testing.allocator, "yarn", "dev");
    defer std.testing.allocator.free(yarn);
    const bun = try package_json.commandPreview(std.testing.allocator, "bun", "dev");
    defer std.testing.allocator.free(bun);
    const deno = try package_json.commandPreview(std.testing.allocator, "deno", "dev");
    defer std.testing.allocator.free(deno);
    const npm = try package_json.commandPreview(std.testing.allocator, "npm", "dev");
    defer std.testing.allocator.free(npm);

    try std.testing.expectEqualStrings("pnpm run dev", pnpm);
    try std.testing.expectEqualStrings("yarn dev", yarn);
    try std.testing.expectEqualStrings("bun run dev", bun);
    try std.testing.expectEqualStrings("deno task dev", deno);
    try std.testing.expectEqualStrings("npm run dev", npm);
}

test "discovery apply merges enabled sources and preserves manual process" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();
    cfg.general.procs_from_make_targets = true;
    cfg.general.procs_from_package_json = true;

    var manual = config.schema.ProcessConfig.empty(std.testing.allocator);
    manual.shell = "make build";
    manual.description = "custom";
    try cfg.procs.put(try std.testing.allocator.dupe(u8, "make:build"), manual);

    try apply_mod.apply(std.testing.allocator, &cfg, "testdata/phase2/discovery");

    try std.testing.expectEqualStrings("custom", cfg.procs.get("make:build").?.description);
    try std.testing.expect(cfg.procs.get("make:test") != null);
    try std.testing.expect(cfg.procs.get("pnpm:dev") != null);
    try std.testing.expect(cfg.procs.get("pnpm:build") != null);
}

test "discovery apply respects disabled sources" {
    var cfg = config.schema.Config.empty(std.testing.allocator);
    defer cfg.deinit();

    try apply_mod.apply(std.testing.allocator, &cfg, "testdata/phase2/discovery");
    try std.testing.expectEqual(@as(usize, 0), cfg.procs.count());
}
