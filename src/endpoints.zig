const std = @import("std");

pub const EndpointPool = struct {
    const Self = @This();

    // fields;
    addr_family: std.Io.net.IpAddress.Family,

    pool: std.ArrayList(Endpoint) = .empty, // Immutable after reading the config

    current_id: std.atomic.Value(usize) = .init(0),

    // public API

    /// Returns an error.WrongFamily if match fails.
    pub fn matchFamily(
        addr: std.Io.net.IpAddress,
        want: std.Io.net.IpAddress.Family,
    ) error{WrongFamily}!void {
        const got: std.Io.net.IpAddress.Family = addr; // tagged union coerces to its tag
        if (got != want) return error.WrongFamily;
    }

    /// Returns an address of the current active endpoint.
    /// Returns null on an empty pool.
    pub fn currentAddr(self: *Self) ?std.Io.net.IpAddress {
        if (self.pool.items.len == 0) return null;
        return self.pool.items[self.current_id.load(.monotonic)].addr;
    }
    /// Returns a health state of the current active endpoint.
    /// Returns null on an empty pool.
    pub fn currentHealth(self: *Self) ?Health {
        if (self.pool.items.len == 0) return null;
        return self.pool.items[self.current_id.load(.monotonic)].health.load(.monotonic);
    }

    /// Used for adding endpoints to the pool,
    /// Complies with address family selected at start.
    pub fn add(
        self: *Self,
        gpa: std.mem.Allocator,
        addr: std.Io.net.IpAddress,
    ) error{ Duplicate, OutOfMemory, WrongFamily }!void {
        // Check if address family matches first
        try matchFamily(addr, self.addr_family);
        // Checking duplicates in the config
        if (self.indexOf(addr) != null) return error.Duplicate;
        try self.pool.append(gpa, .{ .addr = addr });
    }

    /// Set ID directly
    /// Returns false on out-of-bounds.
    pub fn setID(self: *Self, id: u32) bool {
        if (id >= self.pool.items.len) return false;
        self.current_id.store(id, .monotonic);
        return true;
    }

    /// Mark the active endpoint healthy.
    /// no-op on an empty pool.
    pub fn markCurrentGood(self: *Self) void {
        const i: u32 = @intCast(self.current_id.load(.monotonic));
        if (self.getEndpoint(i)) |ep| ep.health.store(.good, .monotonic);
    }

    /// Mark the current endpoint failed,
    /// then advance to the best candidate.
    pub fn failoverToNext(self: *Self, now: i64) bool {
        const old = self.currentAddr();
        const old_id: u32 = @intCast(self.current_id.load(.monotonic));

        // Record the failure
        if (self.getEndpoint(old_id)) |ep| {
            ep.health.store(.failed, .monotonic);
            ep.last_failed_at.store(now, .monotonic);
        }

        // Choose a successor, sweeping onward from where we were so that
        // equal-ranked endpoints rotate instead of always picking the lowest index.
        const new_index = self.nextCandidate(old_id, now);

        var current_ep: ?Endpoint = null;
        if (new_index) |idx| {
            // nextCandidateUnsafe cannot return out-of-bounds index, this is safe.
            self.current_id.store(idx, .monotonic);
            current_ep = self.pool.items[idx];
        }

        const current = if (current_ep) |ep| ep.addr else null;

        return !sameAddr(old, current);
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        self.pool.deinit(gpa);
    }

    // private types and constants

    /// Endpoint reply state
    const Health = enum(u8) { untried, good, failed };

    /// Contains server address, reply state and time when switcher registered a failed reply
    const Endpoint = struct {
        addr: std.Io.net.IpAddress, // constant
        health: std.atomic.Value(Health) = .init(.untried), // Modifiable by switcher only
        last_failed_at: std.atomic.Value(i64) = .init(0), // Modifiable by switcher only
    };

    // private helpers;

    /// Returns an index of the address or null if it does not exist.
    fn indexOf(self: Self, addr: std.Io.net.IpAddress) ?u32 {
        for (0..self.pool.items.len) |i| { // start was already checked
            if (std.Io.net.IpAddress.eql(&self.pool.items[i].addr, &addr))
                return @intCast(i);
        }
        return null;
    }

    /// Helper for comparing optional IP addesses
    fn sameAddr(a: ?std.Io.net.IpAddress, b: ?std.Io.net.IpAddress) bool {
        // If a is null, return true if b is null as well.
        const x = a orelse return b == null;
        // a is assigned, return false if b is null.
        const y = b orelse return false;

        return std.Io.net.IpAddress.eql(&x, &y);
    }

    /// Pick the next candidate, sweeping from just after `from` so equal-ranked
    /// endpoints are tried round-robin. Returns null on empty list.
    fn nextCandidate(self: Self, id: u32, now: i64) ?u32 {
        const pool_len = self.pool.items.len;
        if (pool_len == 0) return null;
        // Set the start of looking for candidates
        const start = (id + 1) % pool_len;

        var best: u32 = @intCast(start);
        var best_rank: u8 = 255;
        var best_age: i64 = -1;

        for (0..pool_len) |iter| {
            // Calculate index for the slot based on number of iterations plus the starting point
            const index = (start + iter) % pool_len;
            const ep = self.pool.items[index];

            const rank: u8 = switch (ep.health.load(.monotonic)) {
                .good => 0,
                .untried => 1,
                .failed => 2,
            };
            const age = now - ep.last_failed_at.load(.monotonic);

            if (rank < best_rank or (rank == best_rank and rank == 2 and age > best_age)) {
                best_rank = rank;
                best_age = age;
                best = @intCast(index);
            }
            if (best_rank == 0) break; // nothing beats a known-good one

        }

        return best;
    }

    /// Backend function that returns an endpoint based upon requested index of the slot.
    /// null represents out-of-bounds.
    fn getEndpoint(self: *Self, index: u32) ?*Endpoint {
        if (index >= self.pool.items.len) return null;
        return &self.pool.items[index];
    }
};

// Tests

const testing = std.testing;

/// A pool, so each test is two lines of setup. The `Io` comes from
/// `std.testing.io`, which the test runner owns and initialises.
const TestCtx = struct {
    const Self = @This();
    pool: EndpointPool,

    fn init(family: std.Io.net.IpAddress.Family) TestCtx {
        return .{ .pool = .{ .addr_family = family } };
    }

    fn deinit(self: *Self) void {
        self.pool.deinit(testing.allocator);
    }

    /// A loopback endpoint distinguished only by port. Returns its slot index.
    fn add(self: *Self, port: u16) !void {
        return self.pool.add(testing.allocator, addr4(port));
    }

    fn addV6(self: *Self, port: u16) !void {
        const a = std.Io.net.IpAddress.parse("::1", port) catch unreachable;
        return self.pool.add(testing.allocator, a);
    }

    /// Reach past the API to set health directly mimicking switcher's inputs.
    fn setHealth(self: *Self, index: u32, h: EndpointPool.Health, failed_at: i64) void {
        const ep = self.pool.getEndpoint(index).?;
        ep.health.store(h, .monotonic);
        ep.last_failed_at.store(failed_at, .monotonic);
    }
};

fn addr4(port: u16) std.Io.net.IpAddress {
    return std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
}

/// Only invariant that holds in 0.16.0 branch is that addressess must be unique.
fn checkUnique(pool: *EndpointPool) !void {
    // Addresses  must be unique
    for (pool.pool.items, 0..) |e, i| {
        const ep1 = e;
        for (pool.pool.items[i + 1 ..]) |b| {
            const ep2 = b;
            try testing.expect(!std.Io.net.IpAddress.eql(&ep1.addr, &ep2.addr));
        }
    }
}

// add

test "add: duplicate check" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    try t.add(1001);
    try testing.expectError(error.Duplicate, t.add(1001));
    try checkUnique(&t.pool);
}

// setID
test "setID: out-of-bounds " {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    // Empty list
    try testing.expect(t.pool.setID(0) == false);
    try t.add(1001);
    try testing.expect(t.pool.setID(1) == false);
}

// currentAddr

test "currentAddr: empty pool" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    try testing.expect(t.pool.currentAddr() == null);
}

// candidate ranking

test "nextCandidate: empty pool yields null" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();
    try testing.expect(t.pool.nextCandidate(0, 100) == null);
}

test "nextCandidate: good outranks untried outranks failed" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    try t.add(1001); // ID 0
    try t.add(1002); // ID 1
    try t.add(1003); // ID 2
    t.setHealth(0, .failed, 50);
    t.setHealth(1, .untried, 0);
    t.setHealth(2, .good, 0);

    try testing.expectEqual(2, t.pool.nextCandidate(0, 100).?);

    t.setHealth(2, .failed, 10); // demote it and untried wins
    try testing.expectEqual(1, t.pool.nextCandidate(0, 100).?);
}

test "nextCandidate: among failed endpoints the oldest failure wins" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    try t.add(1001); // ID 0
    try t.add(1002); // ID 1
    try t.add(1003); // ID 2
    t.setHealth(0, .failed, 90);
    t.setHealth(1, .failed, 10); // longest since it failed
    t.setHealth(2, .failed, 50);

    try testing.expectEqual(1, t.pool.nextCandidate(0, 100).?);
}

test "nextCandidate: cancels out of the ranking" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    try t.add(1001); // ID 0
    try t.add(1002); // ID 1
    t.setHealth(0, .failed, 900);
    t.setHealth(1, .failed, 100);

    const at_zero = t.pool.nextCandidate(0, 0).?;
    try testing.expectEqual(at_zero, t.pool.nextCandidate(0, 1_000_000).?);
    try testing.expectEqual(1, at_zero);
}

test "nextCandidate: equal-ranked endpoints rotate instead of sticking" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    try t.add(1001); // ID 0
    try t.add(1002); // ID 1
    try t.add(1003); // ID 2
    // All untried: the sweep origin decides.
    try testing.expectEqual(1, t.pool.nextCandidate(0, 0).?);
    try testing.expectEqual(2, t.pool.nextCandidate(1, 0).?);
    try testing.expectEqual(0, t.pool.nextCandidate(2, 0).?); // wraps
}

// failover

test "failoverToNext: no alternative endpint" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    try t.add(1001); // ID 0
    const id = t.pool.indexOf(addr4(1001)).?;
    const expect_true = t.pool.setID(id);
    try testing.expect(expect_true);

    _ = t.pool.failoverToNext(1234);

    const failed = t.pool.getEndpoint(0).?;
    try testing.expectEqual(EndpointPool.Health.failed, failed.health.load(.monotonic));
    try testing.expectEqual(@as(i64, 1234), failed.last_failed_at.load(.monotonic));
}

test "failoverToNext: marks the previous endpoint failed with the given timestamp" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    try t.add(1001); // ID 0
    try t.add(1002); // ID 1
    const id = t.pool.indexOf(addr4(1001)).?;
    const expect_true = t.pool.setID(id);
    try testing.expect(expect_true);

    _ = t.pool.failoverToNext(1234);

    const failed = t.pool.getEndpoint(0).?;
    try testing.expectEqual(EndpointPool.Health.failed, failed.health.load(.monotonic));
    try testing.expectEqual(@as(i64, 1234), failed.last_failed_at.load(.monotonic));
}

test "failoverToNext: advances to a different endpoint and reports the change" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    for (0..3) |k| _ = try t.add(@intCast(1000 + k));
    // Initial state is always 0
    try testing.expect(t.pool.current_id.load(.monotonic) == 0);

    const fo = t.pool.failoverToNext(10);
    try testing.expect(fo); // null -> something is a change
    try testing.expect(t.pool.currentAddr() != null);
    try testing.expect(t.pool.current_id.load(.monotonic) != 0);
    try checkUnique(&t.pool);
}

test "failoverToNext: empty pool selects nothing and reports no change" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    const fo = t.pool.failoverToNext(10);
    try testing.expect(!fo);
    try testing.expect(t.pool.currentAddr() == null);
    try testing.expect(t.pool.current_id.load(.monotonic) == 0);
}

test "markCurrentGood: touches just the current endpoint" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    try t.add(1001); // ID 0
    try t.add(1002); // ID 1
    const id = t.pool.indexOf(addr4(1001)).?;
    const expect_true = t.pool.setID(id);
    try testing.expect(expect_true);
    t.pool.markCurrentGood();

    try testing.expectEqual(EndpointPool.Health.good, t.pool.getEndpoint(0).?.health.load(.monotonic));
    try testing.expectEqual(EndpointPool.Health.untried, t.pool.getEndpoint(1).?.health.load(.monotonic));
}

test "markCurrentGood: an empty pool is a no-op" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();
    t.pool.markCurrentGood(); // must not panic
    try testing.expect(t.pool.pool.items.len == 0);
}

test "getEndpoint: ot-of-bounds and empty pool return null" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();
    try t.add(1001); // ID 0
    try t.add(1002); // ID 1

    // out-of-bounds
    try testing.expect(t.pool.getEndpoint(2 + 1) == null);
    // returned endpoint
    try testing.expect(t.pool.getEndpoint(0) != null);
}

// address family

test "matchFamily: accepts a match and rejects the other family" {
    const v4 = try std.Io.net.IpAddress.parse("127.0.0.1", 80);
    const v6 = try std.Io.net.IpAddress.parse("::1", 80);

    try EndpointPool.matchFamily(v4, .ip4);
    try EndpointPool.matchFamily(v6, .ip6);
    try testing.expectError(error.WrongFamily, EndpointPool.matchFamily(v4, .ip6));
    try testing.expectError(error.WrongFamily, EndpointPool.matchFamily(v6, .ip4));
}

test "an ip6 pool accepts ip6 and rejects ip4" {
    var t: TestCtx = .init(.ip6);
    defer t.deinit();

    try t.addV6(1001);
    try testing.expectError(error.WrongFamily, t.add(1002));
    try testing.expectEqual(1, t.pool.pool.items.len);
}

test "sameAddr: handles both nulls, one null, and cross-family" {
    const v4 = try std.Io.net.IpAddress.parse("127.0.0.1", 80);
    const v6 = try std.Io.net.IpAddress.parse("::1", 80);

    try testing.expect(EndpointPool.sameAddr(null, null));
    try testing.expect(!EndpointPool.sameAddr(v4, null));
    try testing.expect(!EndpointPool.sameAddr(null, v4));
    try testing.expect(EndpointPool.sameAddr(v4, v4));
    try testing.expect(!EndpointPool.sameAddr(v4, v6));
    try testing.expect(!EndpointPool.sameAddr(v4, addr4(81)));
}
