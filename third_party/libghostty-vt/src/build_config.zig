//! proctmux libghostty-vt build configuration shim.
//!
//! The vendored terminal package only needs enough of Ghostty's build config
//! surface to compile terminal-state code in lib mode.

const std = @import("std");

pub const Artifact = enum {
    exe,
    lib,
    wasm_module,
};

pub const ReleaseChannel = enum {
    tip,
    stable,
};

pub const Runtime = enum {
    none,
    gtk,
};

pub const Renderer = enum {
    opengl,
    metal,
    webgl,
};

pub const FontBackend = enum {
    freetype,
    coretext,
    web_canvas,
};

pub const ExeEntrypoint = enum {
    ghostty,
};

pub const version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };
pub const version_string = "0.1.0";
pub const release_channel: ReleaseChannel = .tip;
pub const mode_string = @tagName(@import("builtin").mode);
pub const artifact: Artifact = .lib;
pub const exe_entrypoint: ExeEntrypoint = .ghostty;
pub const flatpak = false;
pub const snap = false;
pub const app_runtime: Runtime = .none;
pub const font_backend: FontBackend = .freetype;
pub const renderer: Renderer = .opengl;
pub const i18n = false;
pub const bundle_id = "com.mitchellh.ghostty";
pub const slow_runtime_safety = false;
pub const is_debug = @import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe;
