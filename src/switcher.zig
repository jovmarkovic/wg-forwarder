const std = @import("std");
const EndpointPool = @import("endpoints.zig").EndpointPool;
const nowMs = @import("timestamp.zig").nowMs;
const timer = @import("timestamp.zig").timer;

pub const SwitcherState = struct {
    const Self = @This();

    /// Return values of startOrPlay() function
    pub const PlayOutcome = enum {
        started,
        resumed,
        already_running,
    };
    pub const Status = struct { thread_running: bool, admin_paused: bool, idle_timeout: ?i64 };

    const Tag = enum { running, paused, stopped };
    const State = struct {
        /// Do not set directly, use `setTag()` instead.
        tag: Tag,
        /// Do not set directly, use `setTag()` instead.
        gen: u64,

        /// Use for changing tag and gen state.
        /// no-op on setting the same tag twice.
        fn setTag(self: *State, t: Tag) void {
            if (self.tag == t) return;
            self.tag = t;
            self.gen +%= 1;
        }
    };
    const Work = struct { gen: u64, idle_ms: i64 };
    const Wake = enum {
        changed,
        expired,
        admin_exited,
        admin_paused,
    };

    /// Required to be set by a caller
    io: std.Io,
    /// Required to be set by a caller
    endpoints: *EndpointPool,

    /// Locking
    mutex: std.Io.Mutex = .init,
    /// Wake condition
    cond: std.Io.Condition = .init,

    // Fields manipulated by mutex

    /// Thread handle to allow re-spawning
    thread: ?std.Thread = null,

    /// Switcher internal saved state
    state: State = .{ .tag = .stopped, .gen = 0 },
    /// Failover state if no packets arrived after a switch
    failover: bool = false,
    /// Used to pause a switcher thread
    admin_paused: bool = false,
    /// Required to be set by a caller. Null means "not configured" — `startOrPlay`
    /// refuses to spawn until it is set. Holds how long an endpoint may stay silent
    /// after a sent packet.
    /// Tied to PersistentKeepalive cadence or KEEPALIVE_TIMEOUT packet.
    idle_timeout: ?i64,
    /// While failing over, how fast to advance to the next candidate.
    /// Independent of `idle_timeout`: endpoints × probe_interval should stay
    /// under WireGuard's 90s REKEY_ATTEMPT_TIME.
    probe_interval: i64 = 2,

    /// Returns current switcher state
    pub fn status(self: *Self) Status {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .thread_running = if (self.state.tag != .stopped) true else false,
            .admin_paused = self.admin_paused,
            .idle_timeout = self.idle_timeout,
        };
    }

    /// Switcher function
    pub fn run(self: *Self) void {
        // Clean up if unhandled cancel occurs
        defer {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.state.setTag(.stopped);
        }
        while (true) {
            // Blocks while paused; null means exit. One lock, one snapshot.
            const work = self.threadHandler() orelse break;
            const gen: u64 = work.gen;

            const deadline: i64 = nowMs(self.io) + work.idle_ms;

            switch (self.waitUntil(deadline, gen)) {
                .admin_exited => return,
                .admin_paused => continue, // Park at `threadHandler()`
                .changed => continue, // Take another snapshot from `threadHandler()`
                .expired => {},
            }

            const now: i64 = nowMs(self.io);
            const fo = self.endpoints.failoverToNext(now);
            if (fo.selected) |e| {
                if (fo.changed) {
                    std.log.info("Switched to {d} address: {f} health: {t}", .{
                        e.index, e.endpoint.addr, e.endpoint.health,
                    });
                } else {
                    std.log.warn(
                        "switcher: no alternative endpoint available, retrying {f}",
                        .{e.endpoint.addr},
                    );
                }
            } else {
                std.log.warn("switcher: endpoint pool is empty", .{});
            }
            self.afterFailover();
        }
    }

    /// Sets the duration of switcher's sleep
    pub fn setDuration(self: *Self, seconds: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.idle_timeout = seconds;
        self.cond.broadcast(self.io);
    }

    /// Starts or resumes a switcher thread
    pub fn startOrPlay(self: *Self) !PlayOutcome {
        // Not needed but safe to have it
        self.reapIfExited();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // A live handle and a running flag are set and cleared together.
        std.debug.assert((self.thread != null) and self.state.tag != .stopped);

        if (self.state.tag != .stopped and self.thread != null) {
            if (!self.admin_paused) return .already_running;

            self.admin_paused = false;
            self.cond.broadcast(self.io);
            return .resumed;
        }

        if (self.idle_timeout == null) return error.NoTimerConfigured;
        const old_tag = self.state.tag;

        // Initial running internal state
        self.state.setTag(.paused);
        errdefer self.state.setTag(old_tag);

        // Set admin general pause flag
        self.admin_paused = false;

        std.log.info("Spawning switcher thread....", .{});
        // Use 'self' as the only argument because the struct has been inited
        self.thread = try std.Thread.spawn(.{}, Self.run, .{self});
        return .started;
    }

    /// Stops a switcher thread
    pub fn stop(self: *Self) void {
        var handle: ?std.Thread = null;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.state.setTag(.stopped);
            self.cond.broadcast(self.io);
            handle = self.thread;
            self.thread = null;
        }
        if (handle) |t| t.join(); // Must be outside a lock
        std.log.info("Stopping switcher thread....", .{});
    }

    /// Pauses a switcher thread
    pub fn pause(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.admin_paused = true;
        self.cond.broadcast(self.io);
    }

    /// Reset switcher state and mark current endpoint as valid
    /// Use in forwarder functions.
    pub fn reset(self: *Self) void {
        // markCurrentGood() locks EndpointPool, must be separate from the SwitcherState lock
        self.endpoints.markCurrentGood();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.state.tag != .running) return;
        self.state.setTag(.paused);
    }

    /// Start a switcher timer if it's in `paused` state
    /// Use in forwarder functions.
    pub fn timerStart(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.state.tag != .paused) return;
        self.state.setTag(.running);
    }

    /// Join a thread that exited on its own, so a stale handle can never block a
    /// restart or be overwritten unjoined.
    fn reapIfExited(self: *Self) void {
        var stale: ?std.Thread = null;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.state.tag == .stopped and self.thread != null) {
                stale = self.thread;
                self.thread = null;
            }
        }
        if (stale) |t| t.join(); // must be outside the lock
    }

    /// Blocks while paused. Returns the current snapshot, or null if thread should exit
    fn threadHandler(self: *Self) ?Work {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (true) {
            // Return if thread is stopped
            if (self.state.tag == .stopped) return null;
            // Unconditionally sleep if admin paused the thread
            if (!self.admin_paused and self.state.tag == .running) break;
            self.cond.waitUncancelable(self.io, &self.mutex);
        }

        // Set idle duration while holding the lock
        const idle: i64 = if (self.failover) self.probe_interval else self.idle_timeout.?;
        const idle_ms: i64 = idle * std.time.ms_per_s;

        return .{
            .gen = self.state.gen,
            .idle_ms = idle_ms,
        };
    }

    /// Wait up to `deadline` timestamp in milliseconds.
    /// Waking early on any state change.
    fn waitUntil(self: *Self, deadline: i64, gen: u64) Wake {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Return error.Timeout based on a constructed `Timeout` struct
        const t = timer(deadline);

        // Watch admin stopping or pausing the thread and generation change
        while (self.state.tag != .stopped and !self.admin_paused and self.state.gen == gen) {
            self.cond.waitTimeout(self.io, &self.mutex, t) catch |err| switch (err) {
                error.Timeout => return .expired,
                // For safety in case we switch to another Io implementation
                error.Canceled => return .admin_exited,
            };
        }
        if (self.state.tag == .stopped) return .admin_exited;
        if (self.admin_paused) return .admin_paused;

        // Reset failover while still holding the lock
        self.failover = false;
        return .changed;
    }

    /// Set a failover state to true and park the switcher thread
    fn afterFailover(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.failover = true;
        self.state.setTag(.paused);
    }
};

// Tests

const testing = std.testing;

/// A switcher wired to a caller-owned pool. Nothing below starts the thread, so
/// the pool is never actually consulted — it only has to exist.
fn makeSwitcher(pool: *EndpointPool, timeout: ?i64) SwitcherState {
    return .{ .io = testing.io, .endpoints = pool, .idle_timeout = timeout };
}

test "switcher reports itself dead, unpaused, with the configured timer" {
    var pool: EndpointPool = .init(testing.io, .ip4);
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, 30);
    const st = sw.status();

    try testing.expect(!st.thread_running);
    try testing.expect(!st.admin_paused);
    try testing.expectEqual(@as(?i64, 30), st.idle_timeout);
}

test "switcher with no timer reports a null timeout" {
    var pool: EndpointPool = .init(testing.io, .ip4);
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, null);
    try testing.expectEqual(@as(?i64, null), sw.status().idle_timeout);
}

test "startOrPlay refuses to spawn without a timer" {
    var pool: EndpointPool = .init(testing.io, .ip4);
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, null);
    try testing.expectError(error.NoTimerConfigured, sw.startOrPlay());

    // Failed attempt must not have left the flags half-set.
    const st = sw.status();
    try testing.expect(!st.thread_running);
    try testing.expect(!st.admin_paused);
    try testing.expect(sw.thread == null);
}

test "setDuration is visible through status" {
    var pool: EndpointPool = .init(testing.io, .ip4);
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, 30);
    sw.setDuration(45);
    try testing.expectEqual(@as(?i64, 45), sw.status().idle_timeout);
}

test "setDuration on a timer-less switcher makes startOrPlay viable" {
    // Admin sequence `timer 30` then `play` on a switcher that was configured without one.
    var pool: EndpointPool = .init(testing.io, .ip4);
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, null);
    try testing.expectError(error.NoTimerConfigured, sw.startOrPlay());

    sw.setDuration(30);
    try testing.expectEqual(@as(?i64, 30), sw.status().idle_timeout);
}

test "pause sets the flag and requests a wake even with no thread running" {
    var pool: EndpointPool = .init(testing.io, .ip4);
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, 30);
    sw.pause();

    const st = sw.status();
    try testing.expect(st.admin_paused);
    // Pausing something that was never started must not claim it is running.
    try testing.expect(!st.thread_running);
}

test "stop on a never-started switcher is a no-op" {
    var pool: EndpointPool = .init(testing.io, .ip4);
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, 30);
    sw.stop(); // must not block or panic on a null handle

    const st = sw.status();
    try testing.expect(!st.thread_running);
    try testing.expect(sw.thread == null);

    // main.zig has `defer switcher.stop()` and the console has `stop`, so a
    // double stop is reachable and must also be harmless.
    sw.stop();
    try testing.expect(!sw.status().thread_running);
}

test "startOrPlay invariant holds on a fresh switcher" {
    // startOrPlay asserts (thread != null) == is_running.
    var pool: EndpointPool = .init(testing.io, .ip4);
    defer pool.deinit(testing.allocator);

    const sw = makeSwitcher(&pool, 30);
    try testing.expectEqual(sw.thread != null, sw.is_running);
}

test "probe_interval defaults below the REKEY_ATTEMPT_TIME budget" {
    // WireGuard gives up after 90s. At probe_interval seconds per candidate the
    // switcher can try 90/probe_interval endpoints inside one handshake window;
    // anything beyond that is never reached during a failover.
    var pool: EndpointPool = .init(testing.io, .ip4);
    defer pool.deinit(testing.allocator);

    const sw = makeSwitcher(&pool, 30);
    try testing.expect(sw.probe_interval > 0);
    try testing.expect(sw.probe_interval <= 5);
    try testing.expect(@divTrunc(90, sw.probe_interval) >= 18);
}
