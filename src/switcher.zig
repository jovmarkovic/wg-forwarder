const std = @import("std");
const EndpointPool = @import("endpoints.zig").EndpointPool;
const nowMs = @import("timestamp.zig").nowMs;
const timer = @import("timestamp.zig").timer;

pub const SwitcherState = struct {
    const Self = @This();
    pub const State = enum(u32) { running, paused, stopped };
    endpoints: *EndpointPool,

    /// Switcher running state
    state: std.atomic.Value(State) = .init(.paused),
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
                // park until wgToServer starts it
                while (self.state.load(.acquire) == .paused)
                    try io.futexWait(State, &self.state.raw, .paused);
                // Nothing is setting `stopped` in 0.16.0 but it's safe to have a guard for it
                if (self.state.load(.acquire) == .stopped) return;

                const duration: i64 = if (self.failvover.load(.monotonic)) self.probe_interval else idle;
                const dur_ms: i64 = duration * std.time.ms_per_s;
                const deadline: i64 = nowMs(io) + dur_ms;

                while (self.state.load(.monotonic) == .running) {
                    const now: i64 = nowMs(io);
                    if (now >= deadline) break;
                    try io.futexWaitTimeout(State, &self.state.raw, .running, timer(deadline));
                }
                // If packet had arrived during the sleep, re-start the main loop
                if (self.state.load(.acquire) != .running) continue;

                const now: i64 = nowMs(io);
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
                self.state.store(.paused, .monotonic);
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
        if (self.state.cmpxchgStrong(.running, .paused, .release, .monotonic) == null)
            io.futexWake(State, &self.state.raw, 1);
    }

    /// Start a switcher timer if it's in `paused` state
    pub fn timerStart(self: *Self, io: std.Io) void {
        if (self.state.cmpxchgStrong(.paused, .running, .release, .monotonic) == null)
            io.futexWake(SwitcherState.State, &self.state.raw, 1);
    }
};
