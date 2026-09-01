const std = @import("std");

pub const EndpointPool = struct {
    const Self = @This();

    // public types

    /// Yields live endpoints one at a time, refilling an internal page under the
    /// read lock. The lock is held per refill, never across the whole iteration, so
    /// a slow consumer cannot stall the forwarding threads.
    ///
    /// Not an atomic snapshot: the pool may change between refills, so an endpoint
    /// added or removed mid-iteration may or may not be seen. Fine for `list`.
    ///
    /// The returned `Entry` is a copy and remains valid after the next call.
    const Iterator = struct {
        pub const page_len = 32;

        pool: *Self,
        buf: [page_len]Entry = undefined,
        /// Tracks the number of entires in the buffer
        filled: usize = 0,
        /// Tracks the number of batches that a caller took
        consumed: usize = 0,
        /// Tracks the index of a failed endpoint copy
        /// and signals the end of the pool
        cursor: ?u32 = 0,

        /// Next live endpoint, or null when exhausted.
        pub fn next(it: *Iterator, io: std.Io) ?Entry {
            if (it.consumed == it.filled) {
                it.refill(io);
                if (it.filled == 0) return null;
            }
            const entry = it.buf[it.consumed];
            it.consumed += 1;
            return entry;
        }

        /// Refill a buffer from a point where last batch stopped
        fn refill(it: *Iterator, io: std.Io) void {
            it.filled = 0;
            it.consumed = 0;
            const start = it.cursor orelse return; // no lock taken when exhausted

            it.pool.lock.lockSharedUncancelable(io);
            defer it.pool.lock.unlockShared(io);

            for (it.pool.slots.items[start..], start..) |slot, index| {
                if (slot.endpoint) |e| {
                    // If there is not enough space to copy endpoint
                    // save the index of it for next iteration
                    if (it.filled == it.buf.len) {
                        it.cursor = @intCast(index);
                        return;
                    }
                    it.buf[it.filled] = .{
                        .index = @intCast(index),
                        .endpoint = e,
                    };
                    it.filled += 1;
                }
            }
            it.cursor = null; // reached the end
        }
    };

    // fields; Everything below `lock` is guarded by it
    addr_family: std.Io.net.IpAddress.Family,

    lock: std.Io.RwLock = .init,

    slots: std.ArrayList(Slot) = .empty,

    current: ?std.Io.net.IpAddress = null,

    hint: ?u32 = null,

    free_head: u32 = free_end, // Holds last free slot index or free_end if nothing is free;

    live: usize = 0, // Occupied slot count. `slots.items.len` is the max value

    // public API — each takes the lock itself

    /// Compile-time check that a reply buffer is big enough.
    /// Call it at the buffer's declaration.
    pub fn checkReplyBuf(comptime len: usize) void {
        if (len < min_reply_buf) @compileError(std.fmt.comptimePrint(
            "admin reply buffer is {d} bytes, needs at least {d}",
            .{ len, min_reply_buf },
        ));
    }

    /// Returns a family if address matches the wanted type or an error
    pub fn requireFamily(
        addr: std.Io.net.IpAddress,
        want: std.Io.net.IpAddress.Family,
    ) error{WrongFamily}!std.Io.net.IpAddress {
        const got: std.Io.net.IpAddress.Family = addr; // tagged union coerces to its tag
        return if (got == want) addr else error.WrongFamily;
    }

    /// Returns an address of the current active endpoint if it has it.
    pub fn currentAddr(self: *Self, io: std.Io) ?std.Io.net.IpAddress {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.current;
    }

    /// Return currently active Entry
    pub fn currentEntry(self: *Self, io: std.Io) ?Entry {
        // Using lockSharedUncancelable for reading
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        const addr = self.current orelse return null;
        const i = self.indexOfUnsafe(addr, self.hint) orelse return null;
        return .{ .index = i, .endpoint = self.slots.items[i].endpoint.? };
    }

    /// Creates an instance of the Iterator struct
    pub fn iterate(self: *Self) Iterator {
        return .{ .pool = self };
    }

    /// Format one line per found endpoint into a writer starting at slot `start`.
    /// `find <ip:port>` — O(N), admin-triggered only. Skips free slots.
    pub fn findByAddr(self: *Self, io: std.Io, w: *std.Io.Writer, addr: std.Io.net.IpAddress, start: u32) ?u32 {
        // Buffer size to be at least of a max_find_line is evaluated during comptime
        const max_line = max_find_line;
        // Using lockSharedUncancelable for reading
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        for (self.slots.items[start..], start..) |slot, index| {
            if (slot.endpoint) |e|
                if (std.Io.net.IpAddress.eql(&e.addr, &addr)) {
                    if (w.unusedCapacityLen() < max_line) return @intCast(index);
                    w.print(
                        "Found address: {f} at slot: {d} health: {s}\n",
                        .{ e.addr, @as(u32, @intCast(index)), @tagName(e.health) },
                    ) catch return @intCast(index);
                };
        }
        return null;
    }

    /// Format one line per live endpoint into a writer, starting at slot `start`.
    /// Returns the slot to resume from, or null at the end of a pool.
    pub fn writePage(self: *Self, io: std.Io, w: *std.Io.Writer, start: u32) ?u32 {
        // Buffer size to be at least of a max_list_line is evaluated during comptime
        const max_line = max_list_line;
        // Using lockSharedUncancelable for reading
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        for (self.slots.items[start..], start..) |slot, index| {
            if (slot.endpoint) |e| {
                if (w.unusedCapacityLen() < max_line) return @intCast(index);
                w.print(
                    "Address: {f} slot: {d} health: {s}\n",
                    .{ e.addr, @as(u32, @intCast(index)), @tagName(e.health) },
                ) catch return @intCast(index);
            }
        }
        return null;
    }

    /// Used for adding endpoints to the pool,
    /// Complies with address family selected at start.
    pub fn add(
        self: *Self,
        io: std.Io,
        gpa: std.mem.Allocator,
        addr: std.Io.net.IpAddress,
    ) error{ Duplicate, OutOfMemory, WrongFamily }!u32 {
        // Check if address family matches first
        _ = try requireFamily(addr, self.addr_family);
        // Using lockUncancelable for writing
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        // Checking duplicates after the lock to avoid racing erros
        if (self.indexOfUnsafe(addr, null) != null) return error.Duplicate;
        return try self.addUnsafe(gpa, addr);
    }

    /// Make `address` the active endpoint. Pass an index as a hint for slot location.
    /// Returns false if points at a freed slot and `current` is left unchanged.
    pub fn setCurrent(self: *Self, io: std.Io, hint: ?u32, addr: std.Io.net.IpAddress) bool {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        const i = self.indexOfUnsafe(addr, hint) orelse return false;
        self.current = addr;
        self.hint = i;
        return true;
    }

    /// Edits existing endpoint's addres and
    /// resets health and last_failed_at state.
    pub fn edit(
        self: *Self,
        io: std.Io,
        hint: ?u32,
        old: std.Io.net.IpAddress,
        new: std.Io.net.IpAddress,
    ) error{ Duplicate, NotFound, WrongFamily }!Endpoint {
        // Check for address family before the lock
        _ = try requireFamily(new, self.addr_family);

        // Using lockUncancelable for potenital writing
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        //Check if any address matches
        const index = self.indexOfUnsafe(old, hint) orelse return error.NotFound;

        if (self.indexOfUnsafe(new, null)) |dup| {
            // Search for duplicates needs a different index to trigger
            if (dup != index) return error.Duplicate;
        }
        //Capture the endpoint and save old state
        const ep = self.atUnsafe(index).?; // indexOfUnsafe only returns live slots
        const old_ep = ep.*;
        // Set new values
        ep.addr = new;
        ep.last_failed_at = 0;
        ep.health = .untried;

        // Check if old is current one, reassign to new
        if (sameAddr(self.current, old)) {
            self.current = new;
            self.hint = index; // Updating hint is an optional
        }

        // return old state
        return old_ep;
    }

    /// Remove `address` as an endpoint. Pass an index as a hint for slot position.
    /// Returns null if no address is found after checking the whole pool.
    pub fn removeByAddr(self: *Self, io: std.Io, hint: ?u32, addr: std.Io.net.IpAddress) ?Endpoint {
        // Using lockUncancelable for writing
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        const index = self.indexOfUnsafe(addr, hint) orelse return null;
        const was_current = sameAddr(self.current, addr);

        // Remove first then pick a successor. nextCandidateUnsafe sweeps all the
        // way around the pool. If address is not removed, it can re-select it.
        // `now` is 0 on purpose: the ranking only compares ages against each other,
        // so the constant cancels. Pass a real clock if an absolute rule is added
        // (e.g. "skip anything that failed in the last 30s").
        const removed = self.removeUnsafe(index) orelse return null;

        if (was_current) {
            if (self.nextCandidateUnsafe(index, 0)) |i| {
                self.hint = i;
                self.current = if (self.atUnsafe(i)) |ep| ep.addr else null;
            } else {
                self.current = null; // that was the last one
            }
        }
        return removed;
    }

    /// Mark the active endpoint healthy.
    /// No-op if there is none or the handle is stale.
    pub fn markCurrentGood(self: *Self, io: std.Io) void {
        // Using lockUncancelable for writing
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        const addr = self.current orelse return;
        const i = self.indexOfUnsafe(addr, self.hint) orelse return;
        self.hint = i;
        if (self.atUnsafe(i)) |ep| ep.health = .good;
    }

    /// Mark the current endpoint failed,
    /// then advance to the best candidate.
    pub fn failoverToNext(self: *Self, io: std.Io, now: i64) Failover {
        // Using lockUncancelable for writing
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        // Check the pool size first
        if (self.slots.items.len == 0) {
            self.current = null;
            return .{ .selected = null, .changed = false };
        }

        const previous = self.current;

        // Record the failure if the handle still resolves. An admin may have
        // removed that endpoint since the switcher last looked at it.
        if (previous) |addr| if (self.indexOfUnsafe(addr, self.hint)) |idx| {
            // If previous is found, it's safe to change it directly under a lock.
            if (self.atUnsafe(idx)) |ep| {
                ep.health = .failed;
                ep.last_failed_at = now;
            }
        };

        // Choose a successor, sweeping onward from where we were so that
        // equal-ranked endpoints rotate instead of always picking the lowest index.
        const new_index = self.nextCandidateUnsafe(self.hint, now);

        // Copy the result out, so the caller can log without holding the lock.
        var selected: ?Entry = null;
        if (new_index) |idx| {
            self.hint = idx;
            // nextCandidateUnsafe cannot find null, this is safe.
            const ep = self.slots.items[idx].endpoint.?;
            self.current = ep.addr;
            selected = .{ .index = idx, .endpoint = ep };
        } else {
            self.current = null; // slots exist, but none are live
        }

        const current: ?std.Io.net.IpAddress = if (selected) |s| s.endpoint.addr else null;

        return .{ .selected = selected, .changed = !sameAddr(previous, current) };
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        self.slots.deinit(gpa);
    }

    // private types and constants

    /// Endpoint reply state
    const Health = enum { untried, good, failed };

    /// Contains server address, reply state and time when switcher registered a failed reply
    const Endpoint = struct {
        addr: std.Io.net.IpAddress,
        health: Health = .untried,
        last_failed_at: i64 = 0,
    };

    /// Holds index of the slot and endpoint of the current pool snapshot.
    const Entry = struct { index: u32, endpoint: Endpoint };

    /// Used in a switcher function
    const Failover = struct {
        /// The endpoint now selected. null == pool is empty.
        selected: ?Entry,
        /// False when we re-selected the same endpoint (nowhere else to go).
        changed: bool,
    };

    /// Used by ArrayList for pool allocation
    const Slot = struct {
        endpoint: ?Endpoint = null, // null == free
        next_free: u32 = free_end,
    };

    // constants

    /// Longest message `showStatus` can emit (two lines).
    const max_status_line = ("Switcher: RUNNING timer: 9223372036854775807s\nCurrent slot: 4294967295" ++
        " address: [ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535 health: untried\n").len;
    /// Longest line `writePage` can emit.
    const max_list_line = ("Address: [ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535" ++
        " slot: 4294967295 health: untried\n").len;
    /// Longest line `findByAddr` can emit.
    const max_find_line = ("Found address: [ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535" ++
        " at slot: 4294967295 health: untried\n").len;
    /// Longest line `edit` can emit.
    const max_edit_line = ("Changed [ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535" ++
        " to [ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535 (was health: untried).\n").len;

    /// Smallest reply buffer in which every fixed-shape reply fits whole.
    const min_reply_buf = @max(max_status_line, max_list_line, max_find_line, max_edit_line);

    /// Sets the end of empty slot chain
    const free_end: u32 = std.math.maxInt(u32);

    // private helpers; the caller must already hold the lock

    /// `hint` is an index the operator read from `list` or `find`
    /// for a slot holding `addr`, or null.
    /// It is checked first, and the sweep starts from there.
    /// If not found, search wraps so a near-miss costs a couple of steps instead of N/2.
    /// A wrong hint is never an error, only a slower lookup: the address is the identity.
    fn indexOfUnsafe(self: Self, addr: std.Io.net.IpAddress, hint: ?u32) ?u32 {
        const pool_len: u32 = @intCast(self.slots.items.len);
        if (pool_len == 0) return null;

        // Safe against out of bounds
        const start: u32 = if (hint) |h| (if (h < pool_len) h else 0) else 0;
        if (self.matchUnsafe(start, addr)) return start;

        for (1..pool_len) |k| { // start was already checked
            const index: u32 = @intCast((start + k) % pool_len);
            if (self.matchUnsafe(index, addr)) return index;
        }
        return null;
    }

    /// Check if slot index matches the address
    fn matchUnsafe(self: Self, i: u32, addr: std.Io.net.IpAddress) bool {
        if (self.slots.items[i].endpoint) |e| return std.Io.net.IpAddress.eql(&e.addr, &addr);
        return false;
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
    /// endpoints are tried round-robin. Only use while locked.
    fn nextCandidateUnsafe(self: Self, hint: ?u32, now: i64) ?u32 {
        const pool_len = self.slots.items.len;
        if (pool_len == 0) return null;
        // Set the start of looking for candidates
        const start = if (hint) |id| (id + 1) % pool_len else 0;

        var best: ?u32 = null;
        var best_rank: u8 = 255;
        var best_age: i64 = -1;

        for (0..pool_len) |iter| {
            // Calculate index for the slot based on number of iterations plus the starting point
            const index = (start + iter) % pool_len;
            const slot = &self.slots.items[index];
            const ep = if (slot.endpoint) |*e| e else continue; // skip holes

            const rank: u8 = switch (ep.health) {
                .good => 0,
                .untried => 1,
                .failed => 2,
            };
            const age = now - ep.last_failed_at;

            if (rank < best_rank or (rank == best_rank and rank == 2 and age > best_age)) {
                best_rank = rank;
                best_age = age;
                best = @intCast(index);
            }
            if (best_rank == 0) break; // nothing beats a known-good one

        }

        return best;
    }

    /// Backend function for adding an endpoint
    fn addUnsafe(self: *Self, gpa: std.mem.Allocator, addr: std.Io.net.IpAddress) error{OutOfMemory}!u32 {
        // Pick last freed slot
        if (self.free_head != free_end) {
            const i = self.free_head;
            const slot = &self.slots.items[i];
            self.free_head = slot.next_free; // Move freed before to last freed
            slot.next_free = free_end;
            slot.endpoint = .{ .addr = addr };
            self.live += 1;
            return i;
        }

        try self.slots.append(gpa, .{ .endpoint = .{ .addr = addr } });
        self.live += 1;
        return @intCast(self.slots.items.len - 1);
    }

    /// Backend function that removes the endpoint
    /// based upon requested index of the slot.
    fn removeUnsafe(self: *Self, index: u32) ?Endpoint {
        if (index >= self.slots.items.len) return null;
        const slot = &self.slots.items[index];
        const taken = slot.endpoint orelse return null; // already free

        slot.endpoint = null;
        slot.next_free = self.free_head;
        self.free_head = index;
        self.live -= 1;
        return taken;
    }

    /// Backend function that returns an endpoint
    /// based upon requested index of the slot.
    fn atUnsafe(self: *Self, index: u32) ?*Endpoint {
        if (index >= self.slots.items.len) return null;
        return if (self.slots.items[index].endpoint) |*e| e else null;
    }
};

// Tests

const testing = std.testing;

/// Flip to false to silence the walkthrough test.
const show_dumps = true;

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
    fn add(self: *Self, port: u16) !u32 {
        return self.pool.add(testing.io, testing.allocator, addr4(port));
    }

    fn addV6(self: *Self, port: u16) !u32 {
        const a = std.Io.net.IpAddress.parse("::1", port) catch unreachable;
        return self.pool.add(testing.io, testing.allocator, a);
    }

    /// Reach past the API to set health directly mimicking switcher's inputs.
    fn setHealth(self: *Self, index: u32, h: EndpointPool.Health, failed_at: i64) void {
        const ep = self.pool.atUnsafe(index).?;
        ep.health = h;
        ep.last_failed_at = failed_at;
    }
};

fn addr4(port: u16) std.Io.net.IpAddress {
    return std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
}

/// The invariants the whole pool rests on,
/// must be called after every mutation.
fn expectInvariants(pool: *EndpointPool) !void {
    // `live` tracks what it needs to.
    var occupied: usize = 0;
    for (pool.slots.items) |slot| {
        if (slot.endpoint != null) occupied += 1;
    }
    try testing.expectEqual(occupied, pool.live);

    // The free chain is in range, points only at holes, and terminates.
    var free_count: usize = 0;
    var cursor = pool.free_head;
    while (cursor != EndpointPool.free_end) {
        try testing.expect(cursor < pool.slots.items.len);
        const slot = pool.slots.items[cursor];
        try testing.expect(slot.endpoint == null);
        cursor = slot.next_free;
        free_count += 1;
        // A cycle in the free list would otherwise hang the test runner.
        try testing.expect(free_count <= pool.slots.items.len);
    }

    // Every slot is either live or on the free chain. Nothing is orphaned.
    try testing.expectEqual(pool.slots.items.len, pool.live + free_count);

    // `current` is null or names a live endpoint. The forwarder reads it per
    // packet without resolving, this is what makes that safe.
    if (pool.current) |addr| {
        try testing.expect(pool.indexOfUnsafe(addr, null) != null);
    }

    // Addresses  must be unique
    for (pool.slots.items, 0..) |s, i| {
        const ep1 = s.endpoint orelse continue;
        for (pool.slots.items[i + 1 ..]) |b| {
            const ep2 = b.endpoint orelse continue;
            try testing.expect(!std.Io.net.IpAddress.eql(&ep1.addr, &ep2.addr));
        }
    }
}

// add

test "add: duplicate check" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    _ = try t.add(1001);
    try testing.expectError(error.Duplicate, t.add(1001));

    _ = try t.add(1002);
    _ = t.pool.removeByAddr(testing.io, 0, addr4(1001));

    // No longer a duplicate; slot and the address are both free again.
    try testing.expectEqual(@as(u32, 0), try t.add(1001));
    try expectInvariants(&t.pool);
}

// find

test "findByAddr: reports the matching slot and nothing else" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    _ = try t.add(1001);
    _ = try t.add(1002);
    _ = try t.add(1003);

    var page: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&page);
    try testing.expect(t.pool.findByAddr(testing.io, &writer, addr4(1002), 0) == null);

    try testing.expectEqualStrings(
        "Found address: 127.0.0.1:1002 at slot: 1 health: untried\n",
        writer.buffer[0..writer.end],
    );
}

test "findByAddr: no match writes nothing" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();
    _ = try t.add(1001);

    var page: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&page);
    try testing.expect(t.pool.findByAddr(testing.io, &writer, addr4(9999), 0) == null);
    try testing.expectEqual(0, writer.end);
}

test "findByAddr: a hole is not a match" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    _ = try t.add(1001);
    _ = t.pool.removeByAddr(testing.io, 0, addr4(1001));

    var page: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&page);
    try testing.expect(t.pool.findByAddr(testing.io, &writer, addr4(1001), 0) == null);
    try testing.expectEqual(0, writer.end);
}

test "findByAddr: forward only scan" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();
    for (0..4) |k| _ = try t.add(@intCast(1000 + k));

    var page: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&page);
    try testing.expect(t.pool.findByAddr(testing.io, &writer, addr4(1000), 2) == null);
    try testing.expectEqual(0, writer.end);

    writer = std.Io.Writer.fixed(&page);
    try testing.expect(t.pool.findByAddr(testing.io, &writer, addr4(1003), 2) == null);
    try testing.expect(std.mem.find(u8, writer.buffer[0..writer.end], "127.0.0.1:1003") != null);
}

// edit

test "edit: replaces the address in place, keeping the slot" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    for (0..3) |k| _ = try t.add(@intCast(1000 + k));
    const len_before = t.pool.slots.items.len;

    _ = try t.pool.edit(testing.io, null, addr4(1001), addr4(2001));

    // An edit is not a remove-then-add; same slot, no growth, free list never touched.
    try testing.expectEqual(@as(?u32, 1), t.pool.indexOfUnsafe(addr4(2001), null));
    try testing.expect(t.pool.indexOfUnsafe(addr4(1001), null) == null);
    try testing.expectEqual(len_before, t.pool.slots.items.len);
    try testing.expectEqual(EndpointPool.free_end, t.pool.free_head);
    try testing.expectEqual(3, t.pool.live);
    try expectInvariants(&t.pool);
}

test "edit: returns the previous state and resets health" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    const i = try t.add(1000);
    t.setHealth(i, .failed, 4242);

    const old = try t.pool.edit(testing.io, null, addr4(1000), addr4(2000));

    // What comes back is the endpoint as it was, so the console can report it.
    try testing.expectEqual(@as(u16, 1000), old.addr.ip4.port);
    try testing.expectEqual(EndpointPool.Health.failed, old.health);
    try testing.expectEqual(@as(i64, 4242), old.last_failed_at);

    // The slot is nowritera fresh endpoint.
    const now = t.pool.atUnsafe(i).?;
    try testing.expectEqual(@as(u16, 2000), now.addr.ip4.port);
    try testing.expectEqual(EndpointPool.Health.untried, now.health);
    try testing.expectEqual(@as(i64, 0), now.last_failed_at);
    try expectInvariants(&t.pool);
}

test "edit: editing the current endpoint moves `current` and `hint` with it" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    _ = try t.add(1000);
    const i = try t.add(1001);
    try testing.expect(t.pool.setCurrent(testing.io, null, addr4(1001)));

    _ = try t.pool.edit(testing.io, null, addr4(1001), addr4(2001));

    const cur = t.pool.currentAddr(testing.io) orelse return error.TestExpectedCurrent;
    try testing.expectEqual(@as(u16, 2001), cur.ip4.port);
    try testing.expectEqual(@as(?u32, i), t.pool.hint);
    try expectInvariants(&t.pool);
}

test "edit: editing a non-current endpoint leaves current alone" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    _ = try t.add(1000);
    _ = try t.add(1001);
    try testing.expect(t.pool.setCurrent(testing.io, null, addr4(1000)));

    _ = try t.pool.edit(testing.io, null, addr4(1001), addr4(2001));

    const cur = t.pool.currentAddr(testing.io) orelse return error.TestExpectedCurrent;
    try testing.expectEqual(@as(u16, 1000), cur.ip4.port);
    try expectInvariants(&t.pool);
}

test "edit: self-edit resets health and last_failed_at" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    const i = try t.add(1000);
    t.setHealth(i, .failed, 99);

    const old = try t.pool.edit(testing.io, null, addr4(1000), addr4(1000));
    try testing.expectEqual(EndpointPool.Health.failed, old.health);

    const now = t.pool.atUnsafe(i).?;
    try testing.expectEqual(@as(u16, 1000), now.addr.ip4.port);
    try testing.expectEqual(EndpointPool.Health.untried, now.health);
    try testing.expectEqual(@as(i64, 0), now.last_failed_at);
    try testing.expectEqual(1, t.pool.live);
    try expectInvariants(&t.pool);
}

// remove

test "removeByAddr: the hint follows the successor" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    for (0..3) |k| _ = try t.add(@intCast(1000 + k));
    try testing.expect(t.pool.setCurrent(testing.io, null, addr4(1000)));
    try testing.expectEqual(@as(?u32, 0), t.pool.hint);

    _ = t.pool.removeByAddr(testing.io, 0, addr4(1000));

    const cur = t.pool.currentEntry(testing.io) orelse return error.TestExpectedCurrent;
    try testing.expectEqual(@as(?u32, cur.index), t.pool.hint);
    try expectInvariants(&t.pool);
}

test "removeByAddr: removing the only endpoint leaves no current" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    _ = try t.add(1001);
    try testing.expect(t.pool.setCurrent(testing.io, null, addr4(1001)));
    try testing.expect(t.pool.removeByAddr(testing.io, 0, addr4(1001)) != null);

    try testing.expect(t.pool.current == null);
    try testing.expect(t.pool.currentAddr(testing.io) == null);
    try testing.expectEqual(0, t.pool.live);
    try expectInvariants(&t.pool);
}

test "removeByAddr: removing a non-current endpoint leaves current alone" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    _ = try t.add(1001);
    _ = try t.add(1002);
    try testing.expect(t.pool.setCurrent(testing.io, null, addr4(1001)));
    _ = t.pool.removeByAddr(testing.io, 0, addr4(1002));

    try testing.expect(EndpointPool.sameAddr(t.pool.current, addr4(1001)));
    try expectInvariants(&t.pool);
}

test "removeUnsafe: remove empty returns a null" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    const a = try t.add(1001);
    _ = try t.add(1002);

    try testing.expect(t.pool.removeUnsafe(a) != null);
    try testing.expect(t.pool.removeUnsafe(a) == null); // no-op, not a re-push
    try expectInvariants(&t.pool); // the cycle guard in here is the real assertion

    try testing.expectEqual(a, try t.add(2001)); // one node on the chain
    try testing.expectEqual(@as(u32, 2), try t.add(2002)); // chain empty, append
    try testing.expectEqual(3, t.pool.slots.items.len);
}

// list

test "free list: LIFO reuse before growing the array" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    _ = try t.add(1000);
    _ = try t.add(1001);
    _ = try t.add(1002);
    _ = try t.add(1003);

    _ = t.pool.removeByAddr(testing.io, 0, addr4(1001)); // chain: 1
    _ = t.pool.removeByAddr(testing.io, 0, addr4(1002)); // chain: 2 -> 1
    try expectInvariants(&t.pool);

    try testing.expectEqual(@as(u32, 2), try t.add(2000)); // most recently freed
    try testing.expectEqual(@as(u32, 1), try t.add(2001));
    try testing.expectEqual(4, t.pool.slots.items.len); // no growth
    try expectInvariants(&t.pool);

    // Chain empty now, so the next add must append.
    try testing.expectEqual(@as(u32, 4), try t.add(2002));
    try testing.expectEqual(5, t.pool.slots.items.len);
    try expectInvariants(&t.pool);
}

test "free list: five removals and five additions reuse the same slots in reverse" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    for (0..8) |k| _ = try t.add(@intCast(1000 + k));

    // Each removal pushes onto the head, the chain ends 4 -> 3 -> 2 -> 1 -> 0.
    for (0..5) |k| {
        try testing.expect(t.pool.removeByAddr(testing.io, 0, addr4(@intCast(1000 + k))) != null);
        try testing.expectEqual(@as(u32, @intCast(k)), t.pool.free_head);
        try expectInvariants(&t.pool);
    }
    try testing.expectEqual(3, t.pool.live);
    try testing.expectEqual(8, t.pool.slots.items.len);

    // Additions pop from that head: reverse order of removal.
    for ([_]u32{ 4, 3, 2, 1, 0 }) |want| {
        try testing.expectEqual(want, try t.add(@intCast(2000 + want)));
        try expectInvariants(&t.pool);
    }

    try testing.expectEqual(8, t.pool.live);
    try testing.expectEqual(8, t.pool.slots.items.len);
    try testing.expectEqual(EndpointPool.free_end, t.pool.free_head);
}

test "free list: remove, edit and refill in rounds keep every invariant" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    // One generation per round, 16 endpoints. Round n releases the even
    // half, edits the odd half up to the next generation while those holes are
    // open, then refills the holes with the next generation's evens. After a
    // round every endpoint is one generation newer and the array has not grown.
    // Free list handed back exactly what was released.
    for (0..16) |k| _ = try t.add(@intCast(3000 + k));
    try testing.expect(t.pool.setCurrent(testing.io, null, addr4(3015)));

    var gen: u16 = 3000;
    for (0..3) |_| {
        const next: u16 = gen + 1000;

        // Release the evens.
        var k: u16 = 0;
        while (k < 16) : (k += 2) {
            try testing.expect(t.pool.removeByAddr(testing.io, null, addr4(gen + k)) != null);
            try expectInvariants(&t.pool);
        }
        try testing.expectEqual(8, t.pool.live);
        const free_after_removals = t.pool.free_head;

        // Edit live addresses up to the next generation, with eight holes open.
        // `current` is 3015 + n*1000 — always odd. It is never removed, and
        // every round it is edited, which is what makes it follow the chain of
        // generations at the end.
        k = 1;
        while (k < 16) : (k += 2) {
            _ = try t.pool.edit(testing.io, null, addr4(gen + k), addr4(next + k));
            try expectInvariants(&t.pool);
        }
        // An edit reuses its own slot, so it must not have disturbed the chain.
        try testing.expectEqual(free_after_removals, t.pool.free_head);
        try testing.expectEqual(8, t.pool.live);

        // Refill the holes.
        k = 0;
        while (k < 16) : (k += 2) {
            _ = try t.add(next + k);
            try expectInvariants(&t.pool);
        }
        try testing.expectEqual(16, t.pool.live);
        try testing.expectEqual(16, t.pool.slots.items.len);
        try testing.expectEqual(EndpointPool.free_end, t.pool.free_head);

        gen = next;
    }

    // Three generations on: ports 6000..6015, still in the original 16 slots.
    try testing.expectEqual(16, t.pool.live);
    try testing.expectEqual(16, t.pool.slots.items.len);
    for (0..16) |k| try testing.expect(t.pool.indexOfUnsafe(addr4(@intCast(6000 + k)), null) != null);

    // `current` followed its endpoint through all three edits.
    const cur = t.pool.currentAddr(testing.io) orelse return error.TestExpectedCurrent;
    try testing.expectEqual(@as(u16, 6015), cur.ip4.port);
}

test "free list: functions on error do not cause changes in the pool" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    _ = try t.add(1001);
    _ = try t.add(1002);
    const id3 = try t.add(1003);
    const v6 = try std.Io.net.IpAddress.parse("::1", 2001);

    // Snapshot everything a failed call could change.
    const live_before = t.pool.live;
    const len_before = t.pool.slots.items.len;
    const head_before = t.pool.free_head;

    try testing.expectError(error.Duplicate, t.add(1001));
    try testing.expectError(error.WrongFamily, t.addV6(1002));

    try testing.expectError(error.NotFound, t.pool.edit(testing.io, null, addr4(9999), addr4(2001)));
    try testing.expectError(error.Duplicate, t.pool.edit(testing.io, null, addr4(1001), addr4(1002)));
    try testing.expectError(error.WrongFamily, t.pool.edit(testing.io, null, addr4(1001), v6));

    // The two that report absence by value rather than by error.
    try testing.expect(!t.pool.setCurrent(testing.io, null, addr4(9999)));
    try testing.expect(t.pool.removeByAddr(testing.io, null, addr4(9999)) == null);

    try testing.expectEqual(live_before, t.pool.live);
    try testing.expectEqual(len_before, t.pool.slots.items.len);
    try testing.expectEqual(head_before, t.pool.free_head);
    try testing.expect(t.pool.current == null);
    // No rejected address was inserted as a side effect.
    try testing.expect(t.pool.indexOfUnsafe(addr4(2001), null) == null);
    try expectInvariants(&t.pool);

    _ = t.pool.removeUnsafe(id3);
    const head_with_hole = t.pool.free_head;

    try testing.expectError(error.Duplicate, t.add(1001));
    try testing.expectError(error.WrongFamily, t.addV6(1002));
    try testing.expectError(error.NotFound, t.pool.edit(testing.io, null, addr4(1003), addr4(2003)));
    try testing.expectError(error.Duplicate, t.pool.edit(testing.io, null, addr4(1001), addr4(1002)));
    try testing.expectError(error.WrongFamily, t.pool.edit(testing.io, null, addr4(1001), v6));

    // Removed slot is untouched.
    try testing.expectEqual(2, t.pool.live);
    try testing.expectEqual(3, t.pool.slots.items.len);
    try testing.expectEqual(head_with_hole, t.pool.free_head);
    try testing.expect(t.pool.indexOfUnsafe(addr4(2003), null) == null);
    try expectInvariants(&t.pool);
}

// helpers

// indexOfUnsafe

test "indexOfUnsafe: a wrong hint is invisible in the result" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    for (0..6) |k| _ = try t.add(@intCast(1000 + k));
    _ = t.pool.removeByAddr(testing.io, 0, addr4(1002)); // a hole to trip over

    for ([_]u16{ 1000, 1001, 1003, 1004, 1005 }) |port| {
        const truth = t.pool.indexOfUnsafe(addr4(port), null);
        try testing.expect(truth != null);
        // Every hint: correct, wrong, pointing at the hole, out of range.
        for (0..t.pool.slots.items.len + 5) |h| {
            try testing.expectEqual(truth, t.pool.indexOfUnsafe(addr4(port), @intCast(h)));
        }
    }

    // And an address that is not present stays absent under every hint.
    for (0..t.pool.slots.items.len + 5) |h| {
        try testing.expect(t.pool.indexOfUnsafe(addr4(1002), @intCast(h)) == null);
        try testing.expect(t.pool.indexOfUnsafe(addr4(9999), @intCast(h)) == null);
    }
}

// current selection

test "setCurrent: accepts a live address and rejects an absent one" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    _ = try t.add(1001);
    _ = try t.add(1002);

    try testing.expect(t.pool.setCurrent(testing.io, null, addr4(1001)));
    try testing.expect(EndpointPool.sameAddr(t.pool.current, addr4(1001)));

    // Absent address: rejected, and `current` is left alone.
    try testing.expect(!t.pool.setCurrent(testing.io, null, addr4(9999)));
    try testing.expect(EndpointPool.sameAddr(t.pool.current, addr4(1001)));

    // Freed slot: also rejected.
    _ = t.pool.removeByAddr(testing.io, 0, addr4(1002));
    try testing.expect(!t.pool.setCurrent(testing.io, null, addr4(1002)));
    try testing.expect(EndpointPool.sameAddr(t.pool.current, addr4(1001)));
    try expectInvariants(&t.pool);
}

test "currentAddr/currentEntry: null on an empty pool" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    try testing.expect(t.pool.currentAddr(testing.io) == null);
    try testing.expect(t.pool.currentEntry(testing.io) == null);

    const i = try t.add(1001);
    try testing.expect(t.pool.setCurrent(testing.io, null, addr4(1001)));

    const addr = t.pool.currentAddr(testing.io).?;
    const entry = t.pool.currentEntry(testing.io).?;
    try testing.expectEqual(i, entry.index);
    try testing.expect(std.Io.net.IpAddress.eql(&addr, &entry.endpoint.addr));
}

// candidate ranking

test "nextCandidate: empty pool yields null" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();
    try testing.expect(t.pool.nextCandidateUnsafe(null, 100) == null);
}

test "nextCandidate: good outranks untried outranks failed" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    const a = try t.add(1001);
    const b = try t.add(1002);
    const d = try t.add(1003);
    t.setHealth(a, .failed, 50);
    t.setHealth(b, .untried, 0);
    t.setHealth(d, .good, 0);

    try testing.expectEqual(d, t.pool.nextCandidateUnsafe(null, 100).?);

    t.setHealth(d, .failed, 10); // demote it and untried wins
    try testing.expectEqual(b, t.pool.nextCandidateUnsafe(null, 100).?);
}

test "nextCandidate: among failed endpoints the oldest failure wins" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    const a = try t.add(1001);
    const b = try t.add(1002);
    const d = try t.add(1003);
    t.setHealth(a, .failed, 90);
    t.setHealth(b, .failed, 10); // longest since it failed
    t.setHealth(d, .failed, 50);

    try testing.expectEqual(b, t.pool.nextCandidateUnsafe(null, 100).?);
}

test "nextCandidate: cancels out of the ranking" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    const a = try t.add(1001);
    const b = try t.add(1002);
    t.setHealth(a, .failed, 900);
    t.setHealth(b, .failed, 100);

    const at_zero = t.pool.nextCandidateUnsafe(null, 0).?;
    try testing.expectEqual(at_zero, t.pool.nextCandidateUnsafe(null, 1_000_000).?);
    try testing.expectEqual(b, at_zero);
}

test "nextCandidate: equal-ranked endpoints rotate instead of sticking" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    const a = try t.add(1001);
    const b = try t.add(1002);
    const d = try t.add(1003);
    // All untried: the sweep origin decides.
    try testing.expectEqual(b, t.pool.nextCandidateUnsafe(a, 0).?);
    try testing.expectEqual(d, t.pool.nextCandidateUnsafe(b, 0).?);
    try testing.expectEqual(a, t.pool.nextCandidateUnsafe(d, 0).?); // wraps
}

test "nextCandidate: holes are skipped, not selected" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    const a = try t.add(1001);
    _ = try t.add(1002);
    const d = try t.add(1003);
    _ = t.pool.removeByAddr(testing.io, 0, addr4(1002));

    const picked = t.pool.nextCandidateUnsafe(a, 0).?;
    try testing.expectEqual(d, picked);
    try testing.expect(t.pool.atUnsafe(picked) != null);
}

// failover

test "failoverToNext: marks the previous endpoint failed with the given timestamp" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    const a = try t.add(1001);
    _ = try t.add(1002);
    try testing.expect(t.pool.setCurrent(testing.io, null, addr4(1001)));

    _ = t.pool.failoverToNext(testing.io, 1234);

    const failed = t.pool.atUnsafe(a).?;
    try testing.expectEqual(EndpointPool.Health.failed, failed.health);
    try testing.expectEqual(@as(i64, 1234), failed.last_failed_at);
}

test "failoverToNext: no current selected still picks a candidate" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    for (0..3) |k| _ = try t.add(@intCast(1000 + k));
    try testing.expect(t.pool.current == null);

    const fo = t.pool.failoverToNext(testing.io, 10);
    try testing.expect(fo.changed); // null -> something is a change
    try testing.expect(fo.selected != null);
    try testing.expect(t.pool.current != null);
    try expectInvariants(&t.pool);
}

test "failoverToNext: empty pool selects nothing and reports no change" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    const fo = t.pool.failoverToNext(testing.io, 10);
    try testing.expect(fo.selected == null);
    try testing.expect(!fo.changed);
    try testing.expect(t.pool.current == null);
}

test "failoverToNext: a pool of only holes clears current instead of dangling" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    _ = try t.add(1001);
    try testing.expect(t.pool.setCurrent(testing.io, null, addr4(1001)));
    _ = t.pool.removeUnsafe(0); // free the slot behind current's back

    const fo = t.pool.failoverToNext(testing.io, 10);
    try testing.expect(fo.selected == null);
    try testing.expect(t.pool.current == null);
}

test "markCurrentGood: touches just the current endpoint" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    const a = try t.add(1001);
    const b = try t.add(1002);
    try testing.expect(t.pool.setCurrent(testing.io, null, addr4(1001)));
    t.pool.markCurrentGood(testing.io);

    try testing.expectEqual(EndpointPool.Health.good, t.pool.atUnsafe(a).?.health);
    try testing.expectEqual(EndpointPool.Health.untried, t.pool.atUnsafe(b).?.health);
}

test "markCurrentGood: no current selected is a no-op" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();
    _ = try t.add(1001);
    t.pool.markCurrentGood(testing.io); // must not panic
    try testing.expectEqual(EndpointPool.Health.untried, t.pool.atUnsafe(0).?.health);
}

test "markCurrentGood: set a hint to current" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    for (0..4) |k| _ = try t.add(@intCast(1000 + k));
    try testing.expect(t.pool.setCurrent(testing.io, null, addr4(1002)));

    t.pool.hint = 0; // as if something moved underneath it
    t.pool.markCurrentGood(testing.io);

    try testing.expectEqual(@as(?u32, 2), t.pool.hint);
    try testing.expectEqual(EndpointPool.Health.good, t.pool.atUnsafe(2).?.health);
}

test "atUnsafe: ot-of-bounds and empty slot return null" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();
    const id1 = try t.add(1001);
    const id2 = try t.add(1002);

    // out-of-bounds
    try testing.expect(t.pool.atUnsafe(id2 + 1) == null);
    // empty slot
    _ = t.pool.removeUnsafe(id2);
    try testing.expect(t.pool.atUnsafe(id2) == null);
    // returned endpoint
    try testing.expect(t.pool.atUnsafe(id1) != null);
}

// address family

test "requireFamily: accepts a match and rejects the other family" {
    const v4 = try std.Io.net.IpAddress.parse("127.0.0.1", 80);
    const v6 = try std.Io.net.IpAddress.parse("::1", 80);

    _ = try EndpointPool.requireFamily(v4, .ip4);
    _ = try EndpointPool.requireFamily(v6, .ip6);
    try testing.expectError(error.WrongFamily, EndpointPool.requireFamily(v4, .ip6));
    try testing.expectError(error.WrongFamily, EndpointPool.requireFamily(v6, .ip4));
}

test "an ip6 pool accepts ip6 and rejects ip4" {
    var t: TestCtx = .init(.ip6);
    defer t.deinit();

    _ = try t.addV6(1001);
    try testing.expectError(error.WrongFamily, t.add(1002));
    try testing.expectEqual(1, t.pool.live);
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

// admin output: writePage / findByAddr

/// Drive `writePage` the way `listEndpoints` does, collecting every page.
fn collectPages(t: *TestCtx, page_buf: []u8, out: *std.ArrayList(u8)) !usize {
    var pages: usize = 0;
    var start: ?u32 = 0;
    while (start) |s| {
        var writer = std.Io.Writer.fixed(page_buf);
        start = t.pool.writePage(testing.io, &writer, s);
        try out.appendSlice(testing.allocator, writer.buffer[0..writer.end]);
        pages += 1;
        try testing.expect(pages <= 4096); // livelock guard
    }
    return pages;
}

test "writePage: exact output for a pool with a hole" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    const a = try t.add(1001);
    _ = try t.add(1002);
    _ = try t.add(1003);
    _ = t.pool.removeByAddr(testing.io, 0, addr4(1002));
    t.setHealth(a, .good, 0);

    var page: [512]u8 = undefined;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    _ = try collectPages(&t, &page, &out);

    try testing.expectEqualStrings(
        "Address: 127.0.0.1:1001 slot: 0 health: good\n" ++
            "Address: 127.0.0.1:1003 slot: 2 health: untried\n",
        out.items,
    );
}

test "writePage: a one-line buffer still yields every endpoint exactly once" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    for (0..10) |k| _ = try t.add(@intCast(1000 + k));
    // Holes at both ends of the range and in the middle.
    _ = t.pool.removeByAddr(testing.io, 0, addr4(1000));
    _ = t.pool.removeByAddr(testing.io, 0, addr4(1004));
    _ = t.pool.removeByAddr(testing.io, 0, addr4(1009));

    // Exactly the worst-case line, so at most one line fits per page: every
    // remaining endpoint costs a separate resume.
    var page: [EndpointPool.max_list_line]u8 = undefined;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const pages = try collectPages(&t, &page, &out);

    try testing.expectEqual(7, std.mem.count(u8, out.items, "\n"));
    try testing.expect(pages >= 7);

    // The needle spans the address AND the field after it, so a truncated line
    // can never count as a hit.
    for (0..10) |k| {
        var needle: [48]u8 = undefined;
        const s = try std.fmt.bufPrint(&needle, "Address: 127.0.0.1:{d} slot:", .{1000 + k});
        const want: usize = if (k == 0 or k == 4 or k == 9) 0 else 1;
        try testing.expectEqual(want, std.mem.count(u8, out.items, s));
    }
}

test "writePage: an empty pool writes nothing and terminates" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    var page: [512]u8 = undefined;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const pages = try collectPages(&t, &page, &out);

    try testing.expectEqual(0, out.items.len);
    try testing.expectEqual(1, pages);
}

test "max_line constants match the worst-case line" {
    const worst = try std.Io.net.IpAddress.parse("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", 65535);
    const max_u32: u32 = std.math.maxInt(u32);

    try testing.expectEqual(EndpointPool.max_list_line, std.fmt.count(
        "Address: {f} slot: {d} health: {s}\n",
        .{ worst, max_u32, "untried" },
    ));

    try testing.expectEqual(EndpointPool.max_find_line, std.fmt.count(
        "Found address: {f} at slot: {d} health: {s}\n",
        .{ worst, max_u32, "untried" },
    ));

    try testing.expectEqual(EndpointPool.max_status_line, std.fmt.count(
        "Switcher: {s} timer: {d}s\nCurrent slot: {d} address: {f} health: {s}\n",
        .{ "RUNNING", @as(i64, std.math.maxInt(i64)), max_u32, worst, "untried" },
    ));

    try testing.expectEqual(EndpointPool.max_edit_line, std.fmt.count(
        "Changed {f} to {f} (was health: {s}).\n",
        .{ worst, worst, "untried" },
    ));

    // The documented numbers, so a change shows up in the diff.
    try testing.expectEqual(90, EndpointPool.max_list_line);
    try testing.expectEqual(99, EndpointPool.max_find_line);
    try testing.expectEqual(144, EndpointPool.max_status_line);
    try testing.expectEqual(130, EndpointPool.max_edit_line);
    try testing.expectEqual(144, EndpointPool.min_reply_buf);
}

// iterator

test "iterate yields every live endpoint exactly once across page boundaries" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    // page_len + 5 forces two refills, and the holes exercise the skip path.
    const n = EndpointPool.Iterator.page_len + 5;
    for (0..n) |k| _ = try t.add(@intCast(1000 + k));
    _ = t.pool.removeByAddr(testing.io, 0, addr4(1003));
    _ = t.pool.removeByAddr(testing.io, 0, addr4(1020));

    var seen: usize = 0;
    var last: i64 = -1;
    var it = t.pool.iterate();
    while (it.next(testing.io)) |entry| {
        // Strictly increasing: catches a refill that restarts from slot 0.
        try testing.expect(@as(i64, entry.index) > last);
        last = entry.index;
        try testing.expect(entry.index != 3 and entry.index != 20);
        seen += 1;
        try testing.expect(seen <= n); // non-termination guard
    }
    try testing.expectEqual(n - 2, seen);
}

test "iterate over an empty pool yields nothing" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    var it = t.pool.iterate();
    try testing.expect(it.next(testing.io) == null);
}

// additional coverage

test "writePage resumes from a non-zero start" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();
    for (0..4) |k| _ = try t.add(@intCast(1000 + k));

    var page: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&page);
    try testing.expect(t.pool.writePage(testing.io, &writer, 2) == null);

    try testing.expectEqualStrings(
        "Address: 127.0.0.1:1002 slot: 2 health: untried\n" ++
            "Address: 127.0.0.1:1003 slot: 3 health: untried\n",
        writer.buffer[0..writer.end],
    );
}

// free-chain visualisation

/// One cell of the next_free row. Parentheses mean "this slot is occupied, so
/// its link is a stale leftover that nothing reads".
fn nextFreeCell(slot: EndpointPool.Slot, buf: []u8) []const u8 {
    var num: [12]u8 = undefined;
    const n: []const u8 = if (slot.next_free == EndpointPool.free_end)
        "END"
    else
        std.fmt.bufPrint(&num, "{d}", .{slot.next_free}) catch "?";

    if (slot.endpoint == null) return std.fmt.bufPrint(buf, "{s}", .{n}) catch "?";
    return std.fmt.bufPrint(buf, "({s})", .{n}) catch "?";
}

/// Test-only: render the free chain and the slot table it lives in.
fn dumpFreeChain(pool: *EndpointPool, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("free_head = ");
    var cursor = pool.free_head;
    var hops: usize = 0;
    while (cursor != EndpointPool.free_end) {
        if (cursor >= pool.slots.items.len) {
            try w.writeAll("!! index out of range");
            break;
        }
        try w.print("{d} -> ", .{cursor});
        cursor = pool.slots.items[cursor].next_free;
        hops += 1;
        if (hops > pool.slots.items.len) {
            try w.writeAll("!! cycle");
            break;
        }
    }
    if (cursor == EndpointPool.free_end) try w.writeAll("END");
    try w.print("   (live {d} of {d} slots)\n", .{ pool.live, pool.slots.items.len });

    try w.writeAll("index:     ");
    for (0..pool.slots.items.len) |i| try w.print("{d:>7}", .{i});

    try w.writeAll("\nendpoint:  ");
    for (pool.slots.items) |slot| {
        if (slot.endpoint) |e| {
            const port = switch (e.addr) {
                inline else => |a| a.port,
            };
            try w.print("{d:>7}", .{port});
        } else try w.print("{s:>7}", .{"-"});
    }

    try w.writeAll("\nnext_free: ");
    for (pool.slots.items) |slot| {
        var cell: [16]u8 = undefined;
        try w.print("{s:>7}", .{nextFreeCell(slot, &cell)});
    }

    try w.writeAll("\n");
}

fn dumpToStderr(pool: *EndpointPool, label: []const u8) void {
    var buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    dumpFreeChain(pool, &writer) catch {}; // silently truncates on a very large pool
    std.debug.print("\n{s}\n{s}", .{ label, writer.buffer[0..writer.end] });
}

test "dumpFreeChain: three removals leave three links, not three dangling slots" {
    var t: TestCtx = .init(.ip4);
    defer t.deinit();

    for (0..8) |k| _ = try t.add(@intCast(1000 + k));
    if (show_dumps) dumpToStderr(&t.pool, "full pool:");

    // Non-adjacent removals, to show the chain has nothing to do with adjacency.
    for ([_]u16{ 1006, 1001, 1004 }) |port| {
        _ = t.pool.removeByAddr(testing.io, 0, addr4(port));
        if (show_dumps) {
            var label: [40]u8 = undefined;
            dumpToStderr(&t.pool, std.fmt.bufPrint(&label, "after rm {d}:", .{port}) catch "after rm:");
        }
        try expectInvariants(&t.pool);
    }

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try dumpFreeChain(&t.pool, &writer);
    // Last freed is the head; first freed is the tail.
    try testing.expect(std.mem.startsWith(u8, writer.buffer[0..writer.end], "free_head = 4 -> 1 -> 6 -> END"));

    // Two additions drain it from the head, newest-freed first.
    for ([_]u16{ 2000, 2001 }) |port| {
        _ = try t.add(port);
        if (show_dumps) {
            var label: [40]u8 = undefined;
            dumpToStderr(&t.pool, std.fmt.bufPrint(&label, "after add {d}:", .{port}) catch "after add:");
        }
        try expectInvariants(&t.pool);
    }

    writer = std.Io.Writer.fixed(&buf);
    try dumpFreeChain(&t.pool, &writer);
    try testing.expect(std.mem.startsWith(u8, writer.buffer[0..writer.end], "free_head = 6 -> END"));
}
