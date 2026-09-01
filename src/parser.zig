const std = @import("std");

const Reader = struct {
    parsed: std.json.Parsed(Config),
    buf: []u8,

    /// Helper to get quick access to the config fields
    pub fn config(self: Reader) Config {
        return self.parsed.value;
    }

    /// Deinit of the parsed structure and a buffer that holds the data
    pub fn deinit(self: Reader, gpa: std.mem.Allocator) void {
        self.parsed.deinit();
        gpa.free(self.buf);
    }
};

const Config = struct {
    address_family: std.Io.net.IpAddress.Family = .ip4,
    client_endpoint: Socket,
    forwarder_socket: Socket,
    server_socket: SrvSocket = .{},
    switcher: Switcher,
    log_level: ?[]const u8 = null,
    admin_console: Admin = .{},

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
    const Admin = struct {
        enabled: bool = false,
        address: ?[]const u8 = null,
        port: u16 = 9000,
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
/// Read and parse the config file
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
        .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed },
    );
    return .{ .parsed = parsed, .buf = buf };
}

// Define different config problems as an enum
pub const Problem = enum {
    missing_timer,
    zero_timer,
    id_out_of_range,
    empty_pool_no_console,
};

// Using a set for easier manipulation
pub const Problems = std.EnumSet(Problem);

/// What is wrong with this config. Pure: no logging, no error, no I/O.
/// It can be tested exhaustively and the caller decides how to report.
pub fn check(cfg: Config) Problems {
    var found: Problems = .empty;
    const sw = cfg.switcher;
    const pool_len = sw.endpoints.len;

    if (sw.enabled) {
        if (sw.timer) |t| {
            if (t == 0) found.insert(.zero_timer);
        } else {
            found.insert(.missing_timer);
        }
        if (sw.id >= pool_len and pool_len != 0) found.insert(.id_out_of_range);
    }
    if (pool_len == 0 and !cfg.admin_console.enabled) found.insert(.empty_pool_no_console);

    return found;
}

/// Caller of the check function for usage outside of testing.
/// Validates if a configuration is in a usable state, logging one line per problem.
pub fn validate(cfg: Config) error{InvalidConfig}!void {
    const found = check(cfg);

    if (found.contains(.missing_timer))
        std.log.err("config: switcher.enabled is true but switcher.timer is missing", .{});
    if (found.contains(.zero_timer))
        std.log.err("config: switcher.timer is 0 seconds", .{});
    if (found.contains(.id_out_of_range))
        std.log.err("config: switcher.id is {d} but only {d} endpoints are defined", .{
            cfg.switcher.id, cfg.switcher.endpoints.len,
        });
    if (found.contains(.empty_pool_no_console))
        std.log.err("config: switcher endpoints are empty and admin_console is disabled", .{});

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

fn testConfig(sw: Config.Switcher, adm: Config.Admin) Config {
    return .{
        .client_endpoint = .{ .address = "127.0.0.1", .port = 51820 },
        .forwarder_socket = .{ .address = "127.0.0.1", .port = 61820 },
        .switcher = sw,
        .admin_console = adm,
    };
}

const two_endpoints: []const []const u8 = &.{ "1.2.3.4:5000", "1.2.3.5:5000" };
const no_endpoints: []const []const u8 = &.{};
const admin_on: Config.Admin = .{ .enabled = true, .port = 9000 };
const admin_off: Config.Admin = .{ .enabled = false, .port = 9000 };

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
        admin_on,
    ), &.{});
}

test "validate returns cleanly on a good config" {
    // Only direct call to the wrapper, happy path logs nothing.
    try validate(testConfig(
        .{ .enabled = true, .id = 1, .timer = 30, .endpoints = two_endpoints },
        admin_on,
    ));
}

test "timer: missing value" {
    try expectProblems(testConfig(
        .{ .enabled = true, .id = 0, .timer = null, .endpoints = two_endpoints },
        admin_on,
    ), &.{.missing_timer});
}

test "timer: value set to 0" {
    try expectProblems(testConfig(
        .{ .enabled = true, .id = 0, .timer = 0, .endpoints = two_endpoints },
        admin_on,
    ), &.{.zero_timer});
}

test "timer: missing value when switcher is enabled" {
    try expectProblems(testConfig(
        .{ .enabled = false, .id = 0, .timer = null, .endpoints = two_endpoints },
        admin_on,
    ), &.{});
}

test "endpoint: set active index-out-of-bounds" {
    try expectProblems(testConfig(
        .{ .enabled = true, .id = 2, .timer = 30, .endpoints = two_endpoints },
        admin_on,
    ), &.{.id_out_of_range});
    // Last valid index is fine.
    try expectProblems(testConfig(
        .{ .enabled = true, .id = 1, .timer = 30, .endpoints = two_endpoints },
        admin_on,
    ), &.{});
}

test "endpoint: empty pool when admin_console is false" {
    try expectProblems(testConfig(
        .{ .enabled = false, .id = 0, .timer = null, .endpoints = no_endpoints },
        admin_off,
    ), &.{.empty_pool_no_console});
    // With the console enabled, an empty pool is legitimate .
    try expectProblems(testConfig(
        .{ .enabled = true, .id = 0, .timer = 30, .endpoints = no_endpoints },
        admin_on,
    ), &.{});
}

test "Every independent problem at once" {
    // The whole point of an else-if chain being broken up: one bad config should
    // surface all of its faults in a single run, not one per edit-and-rerun cycle.
    try expectProblems(testConfig(
        .{ .enabled = true, .id = 3, .timer = null, .endpoints = no_endpoints },
        admin_off,
    ), &.{ .missing_timer, .empty_pool_no_console });
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
