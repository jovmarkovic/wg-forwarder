const std = @import("std");
const _zls_main = @import("main.zig"); // for ZLS reference searches

pub const Config = @import("Config.zig");
pub const address = @import("address.zig");
pub const forward = @import("forward.zig");
pub const Switcher = @import("Switcher.zig");
pub const timestamp = @import("timestamp.zig");
pub const EndpointPool = @import("EndpointPool.zig");

test "Testing all" {
    // This forces the compiler to look at all declarations in this file
    std.testing.refAllDecls(@This());
}
