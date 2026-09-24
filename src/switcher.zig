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
    pub const Status = struct { running: bool, paused: bool, idle_timeout: ?i64 };

    const State = enum(u32) {
        running,
        stopped,
        paused,
    };
    const Wake = enum { expired, interrupted, exit };

    /// Fields required for init
    io: std.Io,
    endpoints: *EndpointPool,

    /// Switcher internal running state
    state: std.atomic.Value(State) = .init(.stopped),
    /// Failover state if no packets arrived after a switch
    failvover: std.atomic.Value(bool) = .init(false),
    /// Locking
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    /// Controls; manipulated by mutex
    is_running: bool = false,
    is_paused: bool = false,
    wake_requested: bool = false,

    /// Thread handle to allow re-spawning
    thread: ?std.Thread = null,

    /// Can be null if the thread is not running.
    /// Silence from the current endpoint that means "dead". Tied to PersistentKeepalive cadence.
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
            .running = self.is_running,
            .paused = self.is_paused,
            .idle_timeout = self.idle_timeout,
        };
    }

    /// Switcher function
    pub fn run(self: *Self) void {
        while (true) {
            // Blocks while paused; null means exit. One lock, one snapshot.
            const idle = self.threadHandler() orelse break;

            const duration: i64 = if (self.failvover.load(.monotonic)) self.probe_interval else idle;
            const dur_ms: i64 = duration * std.time.ms_per_s;
            const deadline: i64 = nowMs(self.io) + dur_ms;

            switch (self.waitUntil(deadline)) {
                .exit => return,
                .interrupted => continue, // Somehow go to the start of the main loop
                .expired => {},
            }

            const now: i64 = nowMs(self.io);
            const fo = self.endpoints.failoverToNext(self.io, now);
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
                // Start failover after the change
                self.failvover.store(true, .monotonic);
            } else {
                std.log.warn("switcher: endpoint pool is empty", .{});
            }
        }
    }

    /// Sets the duration of switcher's sleep
    pub fn setDuration(self: *Self, seconds: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.idle_timeout = seconds;
        self.wake_requested = true;
        self.cond.broadcast(self.io);
    }

    /// Starts or resumes a switcher thread
    pub fn startOrPlay(self: *Self) !PlayOutcome {
        self.reapIfExited();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // A live handle and a running flag are set and cleared together.
        std.debug.assert((self.thread != null) == self.is_running);

        if (self.is_running and self.thread != null and self.state.load(.monotonic) != .stopped) {
            if (!self.is_paused) return .already_running;

            self.is_paused = false;
            self.wake_requested = true;
            self.cond.broadcast(self.io);
            return .resumed;
        }

        if (self.idle_timeout == null) return error.NoTimerConfigured;

        //set the states
        self.is_running = true;
        self.state.store(.paused, .release); // Start in a paused sate, not to trigger a timer
        errdefer {
            self.is_running = false;
            self.state.store(.stopped, .release);
        }
        self.is_paused = false;
        self.wake_requested = false;

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
            self.state.store(.stopped, .release);

            self.is_running = false;
            self.wake_requested = true;
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
        self.state.store(.paused, .release);
        self.is_paused = true;
        self.wake_requested = true;
        self.cond.broadcast(self.io);
    }

    /// Reset switcher state and mark current endpoint as valid
    /// Use in forwarder functions.
    pub fn reset(self: *Self, io: std.Io) void {
        self.endpoints.markCurrentGood();
        self.failvover.store(false, .monotonic);
        if (self.state.cmpxchgStrong(.running, .paused, .release, .monotonic) == null)
            io.futexWake(State, &self.state.raw, 1);
    }

    /// Start a switcher timer if it's in `paused` state
    /// Use in forwarder functions.
    pub fn timerStart(self: *Self, io: std.Io) void {
        if (self.state.cmpxchgStrong(.paused, .running, .release, .monotonic) == null)
            io.futexWake(SwitcherState.State, &self.state.raw, 1);
    }

    /// Join a thread that exited on its own, so a stale handle can never block a
    /// restart or be overwritten unjoined.
    fn reapIfExited(self: *Self) void {
        var stale: ?std.Thread = null;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (!self.is_running and self.thread != null) {
                stale = self.thread;
                self.thread = null;
            }
        }
        if (stale) |t| t.join(); // must be outside the lock
    }

    /// Blocks while paused. Returns the current duration, or null if we should exit.
    fn threadHandler(self: *Self) ?i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.is_paused and self.is_running and self.state.load(.monotonic) == .paused) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        self.wake_requested = false; // don't leave a stale wake for the next waitFor
        if (!self.is_running) return null;
        return self.idle_timeout.?;
    }

    /// Wait up to `deadline` timestamp in milliseconds.
    /// Waking early on any state change.
    /// Returns false if the switcher should exit.
    fn waitUntil(self: *Self, deadline: i64) Wake {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Return error.Tiemout based on a duration struct
        const t = timer(deadline);

        while (self.is_running and !self.wake_requested and self.state.load(.monotonic) == .running) {
            self.cond.waitTimeout(self.io, &self.mutex, t) catch |err| switch (err) {
                error.Timeout => {
                    // Reset wake_requested
                    self.wake_requested = false;
                    return .expired;
                },
                // For safety in case we switch to ther Io implementation
                error.Canceled => {
                    self.is_running = false;
                    return .exit;
                },
            };
        }
        // Reset wake_requested
        self.wake_requested = false;
        return if (self.is_running) .interrupted else .exit;
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
    var pool: EndpointPool = .{ .addr_family = .ip4 };
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, 30);
    const st = sw.status();

    try testing.expect(!st.running);
    try testing.expect(!st.paused);
    try testing.expectEqual(@as(?i64, 30), st.idle_timeout);
}

test "switcher with no timer reports a null timeout" {
    var pool: EndpointPool = .{ .addr_family = .ip4 };
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, null);
    try testing.expectEqual(@as(?i64, null), sw.status().idle_timeout);
}

test "startOrPlay refuses to spawn without a timer" {
    var pool: EndpointPool = .{ .addr_family = .ip4 };
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, null);
    try testing.expectError(error.NoTimerConfigured, sw.startOrPlay());

    // Failed attempt must not have left the flags half-set.
    const st = sw.status();
    try testing.expect(!st.running);
    try testing.expect(!st.paused);
    try testing.expect(sw.thread == null);
}

test "setDuration is visible through status" {
    var pool: EndpointPool = .{ .addr_family = .ip4 };
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, 30);
    sw.setDuration(45);
    try testing.expectEqual(@as(?i64, 45), sw.status().idle_timeout);

    // It clears any pending sleep, so a running thread re-reads it promptly.
    try testing.expect(sw.wake_requested);
}

test "setDuration on a timer-less switcher makes startOrPlay viable" {
    // Admin sequence `timer 30` then `play` on a switcher that was configured without one.
    var pool: EndpointPool = .{ .addr_family = .ip4 };
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, null);
    try testing.expectError(error.NoTimerConfigured, sw.startOrPlay());

    sw.setDuration(30);
    try testing.expectEqual(@as(?i64, 30), sw.status().idle_timeout);
}

test "pause sets the flag and requests a wake even with no thread running" {
    var pool: EndpointPool = .{ .addr_family = .ip4 };
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, 30);
    sw.pause();

    const st = sw.status();
    try testing.expect(st.paused);
    try testing.expect(sw.wake_requested);
    // Pausing something that was never started must not claim it is running.
    try testing.expect(!st.running);
}

test "stop on a never-started switcher is a no-op" {
    var pool: EndpointPool = .{ .addr_family = .ip4 };
    defer pool.deinit(testing.allocator);

    var sw = makeSwitcher(&pool, 30);
    sw.stop(); // must not block or panic on a null handle

    const st = sw.status();
    try testing.expect(!st.running);
    try testing.expect(sw.thread == null);

    // main.zig has `defer switcher.stop()` and the console has `stop`, so a
    // double stop is reachable and must also be harmless.
    sw.stop();
    try testing.expect(!sw.status().running);
}

test "startOrPlay invariant holds on a fresh switcher" {
    // startOrPlay asserts (thread != null) == is_running.
    var pool: EndpointPool = .{ .addr_family = .ip4 };
    defer pool.deinit(testing.allocator);

    const sw = makeSwitcher(&pool, 30);
    try testing.expectEqual(sw.thread != null, sw.is_running);
}

test "probe_interval defaults below the REKEY_ATTEMPT_TIME budget" {
    // WireGuard gives up after 90s. At probe_interval seconds per candidate the
    // switcher can try 90/probe_interval endpoints inside one handshake window;
    // anything beyond that is never reached during a failover.
    var pool: EndpointPool = .{ .addr_family = .ip4 };
    defer pool.deinit(testing.allocator);

    const sw = makeSwitcher(&pool, 30);
    try testing.expect(sw.probe_interval > 0);
    try testing.expect(sw.probe_interval <= 5);
    try testing.expect(@divTrunc(90, sw.probe_interval) >= 18);
}
