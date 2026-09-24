const std = @import("std");

const Reader = struct {
    parsed: std.json.Parsed(Config),
    buf: []u8,

    /// Helper to get quick access to the config fields
    pub fn config(self: Reader) Config {
        return self.parsed.value;
    }

    /// Deinit of the parsed structure and a buffer that holds the data
    pub fn deinit(self: *Reader, gpa: std.mem.Allocator) void {
        self.parsed.deinit();
        gpa.free(self.buf);
        self.* = undefined;
    }
};

const Config = struct {
    address_family: std.Io.net.IpAddress.Family = .ip4,
    client_endpoint: Socket,
    forwarder_socket: Socket,
    server_socket: SrvSocket = .{},
    switcher: Switcher,
    log_level: ?[]const u8 = null,

    const Socket = struct {
        address: []const u8,
        port: u16,
    };

    const SrvSocket = struct {
        address: ?[]const u8 = null,
        port: u16 = 0,
    };

    const Switcher = struct {
        enabled: bool,
        id: u32,
        timer: ?u32 = null,
        endpoints: []const []const u8,
    };
};

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

pub fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Reader {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .lock = .exclusive,
    });
    defer file.close(io);

    const buf = try gpa.alloc(u8, try file.length(io));
    // Only on error, it holds actual data where parser is pointing to
    errdefer gpa.free(buf);

    var reader = file.reader(io, buf);
    // Read all content of a file into buffer
    try reader.interface.readSliceAll(buf);

    const parsed = try std.json.parseFromSlice(
        Config,
        gpa,
        buf,
        .{ .ignore_unknown_fields = true },
    );
    return Reader{ .parsed = parsed, .buf = buf };
}

// Define different config problems as an enum
pub const Problem = enum {
    empty_pool,
    zero_timer,
    missing_timer,
    out_of_bounds,
};

// Using a set for easier manipulation
pub const Problems = std.EnumSet(Problem);

/// Can be used in tests directly.
/// Returns problems that are logical, not picked up by a parser.
pub fn check(cfg: Config) Problems {
    var found: Problems = .empty;
    const sw = cfg.switcher;
    const pool_len = sw.endpoints.len;

    if (sw.enabled) {
        if (sw.timer) |t| {
            if (t == 0) found.insert(.zero_timer);
            if (t < 12) std.log.warn("Switcher time is < 12s! Make sure to have PersistentKeepalive set.", .{});
        } else {
            found.insert(.missing_timer);
        }
        // Negative index is reported by the parser itself
        if (sw.id >= pool_len) found.insert(.out_of_bounds);
    }
    if (pool_len == 0) found.insert(.empty_pool);

    return found;
}

/// Caller of the check function for usage outside of testing.
/// Validates if a configuration is in a usable state, logging one line per problem.
pub fn validate(cfg: Config) error{InvalidConfig}!void {
    const found = check(cfg);

    if (found.contains(.zero_timer))
        std.log.err("config: switcher.timer is 0 seconds", .{});
    if (found.contains(.empty_pool))
        std.log.err("config: switcher endpoints are empty", .{});
    if (found.contains(.missing_timer))
        std.log.err("config: switcher.enabled is true but switcher.timer is missing", .{});
    if (found.contains(.out_of_bounds))
        std.log.err("config: switcher.id is {d} but only {d} endpoints are defined", .{
            cfg.switcher.id, cfg.switcher.endpoints.len,
        });

    if (found.count() != 0) return error.InvalidConfig;
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

fn testConfig(sw: Config.Switcher) Config {
    return .{
        .client_endpoint = .{ .address = "127.0.0.1", .port = 51820 },
        .forwarder_socket = .{ .address = "127.0.0.1", .port = 61820 },
        .switcher = sw,
    };
}

const two_endpoints: []const []const u8 = &.{ "1.2.3.4:5000", "1.2.3.5:5000" };
const no_endpoints: []const []const u8 = &.{};

// validate

// Using `check()` directly, not `validate()`. Two reasons: the assertions become
// exact (which problem, not merely "some problem"), and the test runner fails a
// run if it encounteres std.log.err(). Testing `validate()` directly would display
// successful error tests as a fail when it should not.

/// Use only in tests.
/// Wrapper for an enum set.
fn expectProblems(cfg: Config, expected: []const Problem) !void {
    var want: Problems = .empty;
    for (expected) |p| want.insert(p);
    try testing.expectEqual(want, check(cfg));
}

test "check accepts a well-formed config" {
    try expectProblems(testConfig(
        .{ .enabled = true, .id = 1, .timer = 30, .endpoints = two_endpoints },
    ), &.{});
}

test "validate returns cleanly on a good config" {
    // Only direct call to the wrapper, happy path logs nothing.
    try validate(testConfig(
        .{ .enabled = true, .id = 1, .timer = 30, .endpoints = two_endpoints },
    ));
}

test "timer: missing value" {
    try expectProblems(testConfig(
        .{ .enabled = true, .id = 0, .timer = null, .endpoints = two_endpoints },
    ), &.{.missing_timer});
}

test "timer: value set to 0" {
    try expectProblems(testConfig(
        .{ .enabled = true, .id = 0, .timer = 0, .endpoints = two_endpoints },
    ), &.{.zero_timer});
}

test "timer: missing value when switcher is disabled" {
    try expectProblems(testConfig(
        .{ .enabled = false, .id = 0, .timer = null, .endpoints = two_endpoints },
    ), &.{});
}

test "endpoint: out-of-bounds" {
    try expectProblems(testConfig(
        .{ .enabled = true, .id = 2, .timer = 30, .endpoints = two_endpoints },
    ), &.{.out_of_bounds});
    // Last valid index is fine.
    try expectProblems(testConfig(
        .{ .enabled = true, .id = 1, .timer = 30, .endpoints = two_endpoints },
    ), &.{});
}

test "endpoint: empty pool" {
    try expectProblems(testConfig(
        .{ .enabled = false, .id = 0, .timer = null, .endpoints = no_endpoints },
    ), &.{.empty_pool});
}

test "Every independent problem at once" {
    try expectProblems(testConfig(
        .{ .enabled = true, .id = 3, .timer = null, .endpoints = no_endpoints },
    ), &.{ .out_of_bounds, .missing_timer, .empty_pool });
}

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
