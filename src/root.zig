const std = @import("std");
const _zls_main = @import("main.zig"); // for ZLS referece searches

pub const parser = @import("parser.zig");
pub const forward = @import("forward.zig");
pub const switcher = @import("switcher.zig");
pub const endpoints = @import("endpoints.zig");
pub const timestamp = @import("timestamp.zig");

test "Testing all" {
    // This forces the compiler to look at all declarations in this file
    std.testing.refAllDecls(@This());
}
