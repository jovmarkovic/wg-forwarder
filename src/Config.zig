const std = @import("std");
const Config = @This();

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
    max_sessions: u32 = 1,
    address: ?[]const u8 = null,
    port: u16 = 9000,
};

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
    zero_timer,
    missing_timer,
    id_out_of_range,
    zero_max_sessions,
    empty_pool_no_console,
};

// Using a set for easier manipulation
pub const Problems = std.EnumSet(Problem);

/// What is wrong with this config. Pure: no logging, no error, no I/O.
/// It can be tested exhaustively and the caller decides how to report.
pub fn check(cfg: Config) Problems {
    var found: Problems = .empty;
    const adm = cfg.admin_console;
    const sw = cfg.switcher;
    const pool_len = sw.endpoints.len;

    if (sw.enabled) {
        if (sw.timer) |t| {
            if (t == 0) found.insert(.zero_timer);
            if (t < 12) std.log.warn("Switcher time is < 12s! Make sure to have PersistentKeepalive set.", .{});
        } else {
            found.insert(.missing_timer);
        }
        if (sw.id >= pool_len and pool_len != 0) found.insert(.id_out_of_range);
    }
    if (pool_len == 0 and !adm.enabled) found.insert(.empty_pool_no_console);
    if (adm.enabled and adm.max_sessions == 0) found.insert(.zero_max_sessions);

    return found;
}

/// Caller of the check function for usage outside of testing.
/// Validates if a configuration is in a usable state, logging one line per problem.
pub fn validate(cfg: Config) error{InvalidConfig}!void {
    const found = check(cfg);

    if (found.contains(.zero_timer))
        std.log.err("config: switcher.timer is 0 seconds", .{});
    if (found.contains(.missing_timer))
        std.log.err("config: switcher.enabled is true but switcher.timer is missing", .{});
    if (found.contains(.id_out_of_range))
        std.log.err("config: switcher.id is {d} but only {d} endpoints are defined", .{
            cfg.switcher.id, cfg.switcher.endpoints.len,
        });
    if (found.contains(.zero_max_sessions))
        std.log.err("config: admin_console is enabled but max_sessions is set to 0", .{});
    if (found.contains(.empty_pool_no_console))
        std.log.err("config: switcher endpoints are empty and admin_console is disabled", .{});

    if (found.count() != 0) return error.InvalidConfig;
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
const valid_sw: Config.Switcher = .{ .enabled = true, .endpoints = two_endpoints, .id = 0, .timer = 19 };
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

test "endpoint: max_sessions when admin_console is true" {
    try expectProblems(testConfig(
        valid_sw,
        .{ .enabled = false, .max_sessions = 0 },
    ), &.{});
    // With the console enabled, max_sessions cannot be 0.
    try expectProblems(testConfig(
        valid_sw,
        .{ .enabled = true, .max_sessions = 0 },
    ), &.{.zero_max_sessions});
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
