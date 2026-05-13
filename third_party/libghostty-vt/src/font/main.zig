//! proctmux libghostty-vt font shim.

pub const Backend = enum {
    freetype,
    coretext,
    web_canvas,
};

pub const Face = opaque {};
