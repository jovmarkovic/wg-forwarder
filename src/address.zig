const std = @import("std");
/// Returns public bind based upon address family
pub fn anyAddress(f: std.Io.net.IpAddress.Family) []const u8 {
    return switch (f) {
        .ip4 => "0.0.0.0",
        .ip6 => "::",
    };
}

/// Returns loopback based upon address family
pub fn loopback(f: std.Io.net.IpAddress.Family) []const u8 {
    return switch (f) {
        .ip4 => "127.0.0.1",
        .ip6 => "::1",
    };
}

pub const AddrParseError = error{
    MissingPort,
    BracketsRequired,
    UnterminatedBracket,
    InvalidPort,
    InvalidAddress,
};

/// Accepts `1.2.3.4:5000` and `[::1]:5000`. Bare IPv6 without brackets is
/// rejected as ambiguous — `::1:5000` could be an address or an address+port.
pub fn parseHostPort(s: []const u8) AddrParseError!std.Io.net.IpAddress {
    if (s.len == 0) return error.MissingPort;

    if (s[0] == '[') {
        const close = std.mem.findScalar(u8, s, ']') orelse return error.UnterminatedBracket;
        if (close + 1 >= s.len or s[close + 1] != ':') return error.MissingPort;
        const port = std.fmt.parseInt(u16, s[close + 2 ..], 10) catch return error.InvalidPort;
        return std.Io.net.IpAddress.parse(s[1..close], port) catch error.InvalidAddress;
    }

    const last = std.mem.findScalarLast(u8, s, ':') orelse return error.MissingPort;
    // More than one colon and no brackets: genuinely ambiguous.
    if (std.mem.findScalar(u8, s, ':').? != last) return error.BracketsRequired;

    const port = std.fmt.parseInt(u16, s[last + 1 ..], 10) catch return error.InvalidPort;
    return std.Io.net.IpAddress.parse(s[0..last], port) catch error.InvalidAddress;
}

// Tests

const testing = std.testing;

// parseHostPort

test "parseHostPort: IPv4" {
    const a = try parseHostPort("1.2.3.4:5000");
    try testing.expectEqual(std.Io.net.IpAddress.Family.ip4, @as(std.Io.net.IpAddress.Family, a));
    try testing.expectEqual(@as(u16, 5000), a.ip4.port);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &a.ip4.bytes);
}

test "parseHostPort: bracketed IPv6" {
    for ([_][]const u8{ "[::1]:5000", "[fe80::1]:5000", "[2001:db8::dead:beef]:5000" }) |s| {
        const a = try parseHostPort(s);
        try testing.expectEqual(std.Io.net.IpAddress.Family.ip6, @as(std.Io.net.IpAddress.Family, a));
        try testing.expectEqual(@as(u16, 5000), a.ip6.port);
    }
}

test "parseHostPort: bare IPv6" {
    try testing.expectError(error.BracketsRequired, parseHostPort("::1:5000"));
    try testing.expectError(error.BracketsRequired, parseHostPort("fe80::1:5000"));
}

test "parseHostPort: missing port" {
    try testing.expectError(error.MissingPort, parseHostPort(""));
    try testing.expectError(error.MissingPort, parseHostPort("1.2.3.4"));
    try testing.expectError(error.MissingPort, parseHostPort("[::1]"));
}

test "parseHostPort: unterminated bracket" {
    try testing.expectError(error.UnterminatedBracket, parseHostPort("[::1"));
    try testing.expectError(error.UnterminatedBracket, parseHostPort("["));
}

test "parseHostPort: invalid port" {
    try testing.expectError(error.InvalidPort, parseHostPort("1.2.3.4:"));
    try testing.expectError(error.InvalidPort, parseHostPort("1.2.3.4:abc"));
    try testing.expectError(error.InvalidPort, parseHostPort("1.2.3.4:65536"));
    try testing.expectError(error.InvalidPort, parseHostPort("1.2.3.4:-1"));
    try testing.expectError(error.InvalidPort, parseHostPort("[::1]:70000"));
}

test "parseHostPort: invalid address" {
    try testing.expectError(error.InvalidAddress, parseHostPort("999.1.1.1:80"));
    try testing.expectError(error.InvalidAddress, parseHostPort("1.2.3:80"));
    try testing.expectError(error.InvalidAddress, parseHostPort("[gggg::1]:80"));
    try testing.expectError(error.InvalidAddress, parseHostPort("nothost:80"));
}

test "parseHostPort accepts std.Io.net.IpAddress prints" {
    // The admin console takes addresses with {f} and passes them back on the next
    // command, so print/parse has to round-trip — including the v6 brackets.
    for ([_][]const u8{ "127.0.0.1:1001", "[::1]:1001", "[2001:db8::1]:65535" }) |s| {
        const a = try parseHostPort(s);
        var buf: [64]u8 = undefined;
        const printed = try std.fmt.bufPrint(&buf, "{f}", .{a});
        const b = try parseHostPort(printed);
        try testing.expect(std.Io.net.IpAddress.eql(&a, &b));
    }
}

// family helpers

test "anyAddress and loopback parse as the family they claim" {
    inline for ([_]std.Io.net.IpAddress.Family{ .ip4, .ip6 }) |f| {
        const any = try std.Io.net.IpAddress.parse(anyAddress(f), 0);
        const lo = try std.Io.net.IpAddress.parse(loopback(f), 0);
        try testing.expectEqual(f, @as(std.Io.net.IpAddress.Family, any));
        try testing.expectEqual(f, @as(std.Io.net.IpAddress.Family, lo));
    }
}
