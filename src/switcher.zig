const std = @import("std");
const EndpointPool = @import("endpoints.zig").EndpointPool;
const nowMs = @import("timestamp.zig").nowMs;
const timer = @import("timestamp.zig").timer;

pub const SwitcherState = struct {
    const Self = @This();
    const Tag = enum(u2) { running, paused, stopped };
    pub const State = packed struct(u32) { tag: Tag, gen: u30 }; // Tag = enum(u2)
    endpoints: *EndpointPool,

    /// Switcher running state
    state: std.atomic.Value(State) = .init(.{ .tag = .paused, .gen = 0 }),
    /// Failover state if no packets arrived after a switch
    failvover: std.atomic.Value(bool) = .init(false),

    /// Can be null if the thread is not running.
    /// Silence from the current endpoint that means "dead". Tied to PersistentKeepalive cadence.
    idle_timeout: ?i64,
    /// While failing over, how fast to advance to the next candidate.
    /// Independent of `idle_timeout`: endpoints × probe_interval should stay
    /// under WireGuard's 90s REKEY_ATTEMPT_TIME.
    probe_interval: i64 = 2,

    pub fn run(self: *Self, io: std.Io) error{ FailedToUnwrap, Canceled }!void {
        // Unwrap timer optional
        if (self.idle_timeout) |idle| {
            while (true) {
                var wait_state = self.state.load(.acquire);
                // Monitor just for tag change
                while (wait_state.tag == .paused) {
                    try io.futexWait(State, &self.state.raw, wait_state);
                    // Save new state after wait
                    wait_state = self.state.load(.acquire);
                }
                if (wait_state.tag == .stopped) return;
                // Make a wait_state immutable for the rest of the code
                const timeout_state = wait_state;

                const duration: i64 = if (self.failvover.load(.monotonic)) self.probe_interval else idle;
                const dur_ms: i64 = duration * std.time.ms_per_s;
                const deadline: i64 = nowMs(io) + dur_ms;

                try io.futexWaitTimeout(State, &self.state.raw, timeout_state, timer(deadline));

                if (!std.meta.eql(timeout_state, self.state.load(.acquire))) {
                    self.failvover.store(false, .monotonic);
                    continue;
                }

                const now = nowMs(io);

                const changed = self.endpoints.failoverToNext(now);
                if (changed) {
                    std.log.info("Switched to ID: {d} address: {?f} health: {?t}", .{
                        self.endpoints.current_id.load(.monotonic),
                        self.endpoints.currentAddr(),
                        self.endpoints.currentHealth(),
                    });
                } else {
                    std.log.warn(
                        "switcher: no alternative endpoint available, retrying {?f}",
                        .{self.endpoints.currentAddr()},
                    );
                }
                self.failvover.store(true, .monotonic);
                _ = self.state.cmpxchgStrong(
                    timeout_state,
                    .{ .tag = .paused, .gen = timeout_state.gen +% 1 },
                    .release,
                    .monotonic,
                );
            }
        } else {
            std.log.err("Switcher got called but timer variable value is: {?d}", .{self.idle_timeout});
            return error.FailedToUnwrap;
        }
    }

    /// Reset switcher state and mark current endpoint as valid
    pub fn reset(self: *Self, io: std.Io) void {
        self.endpoints.markCurrentGood();
        self.failvover.store(false, .monotonic);
        const state = self.state.load(.acquire);
        if (state.tag != .running) return;

        const cmpxchg = self.state.cmpxchgStrong(
            state,
            .{ .tag = .paused, .gen = state.gen +% 1 },
            .release,
            .monotonic,
        );
        if (cmpxchg == null) io.futexWake(State, &self.state.raw, 1);
    }

    /// Start a switcher timer if it's in `paused` state
    pub fn timerStart(self: *Self, io: std.Io) void {
        const state = self.state.load(.acquire);
        if (state.tag != .paused) return;

        const cmpxchg = self.state.cmpxchgStrong(
            state,
            .{ .tag = .running, .gen = state.gen +% 1 },
            .release,
            .monotonic,
        );
        if (cmpxchg == null) io.futexWake(State, &self.state.raw, 1);
    }
};
