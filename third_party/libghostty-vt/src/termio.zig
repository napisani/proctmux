//! proctmux libghostty-vt termio shim.

pub const Message = struct {
    pub const WriteReq = struct {
        pub const Small = struct {
            pub const Max: usize = 4096;
        };
    };
};
