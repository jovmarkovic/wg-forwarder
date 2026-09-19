const std = @import("std");
const EndpointPool = @import("endpoints.zig").EndpointPool;
const nowMs = @import("timestamp.zig").nowMs;
const waitUntil = @import("timestamp.zig").waitUntil;

pub const SwitcherState = struct {
    const Self = @This();
    endpoints: *EndpointPool,

    /// Timestamp of an oldest packet arrived from the client before a reply
    first_send_at: std.atomic.Value(i64) = .init(0),
    /// Timestamp of a newest packet arrived from the endpoint
    last_reply_at: std.atomic.Value(i64) = .init(0),
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
            // Declare constants once before the main loop
            var failing_over = false;
            // Reset packet timestamps
            self.first_send_at.store(nowMs(io), .monotonic);
            self.last_reply_at.store(nowMs(io), .monotonic);

            while (true) {
                const last_send = self.first_send_at.load(.monotonic);
                const last_reply = self.last_reply_at.load(.monotonic);
                const duration: i64 = if (failing_over) self.probe_interval else idle;
                const dur_ms: i64 = duration * std.time.ms_per_s;

                std.log.debug("switcher: dur_ms={d}ms last_send={d}ms last_reply={d}ms", .{
                    dur_ms, last_send, last_reply,
                });

                // Check if more than duration had passed between send and a reply.
                if (last_send > last_reply) {
                    const deadline: i64 = last_send + dur_ms;
                    const now: i64 = nowMs(io);
                    // If deadline is not met, sleep for the reamainder
                    if (now < deadline) {
                        try waitUntil(io, deadline);
                        continue;
                    }

                    const changed = self.endpoints.failoverToNext(nowMs(io));
                    if (changed) {
                        std.log.info("Switched to {d} address: {?f} health: {?t}", .{
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
                    // give the new endpoint a fresh window
                    self.last_reply_at.store(nowMs(io), .monotonic);
                    failing_over = true;
                    // If packed had arrived in time mark the connection as good.
                } else if (last_reply > 0 and last_send <= last_reply) {
                    self.endpoints.markCurrentGood();
                    failing_over = false;
                }
                // Sleep at the end for `duration`
                try io.sleep(.fromSeconds(duration), .awake);
            }
        } else {
            std.log.err("Switcher got called but timer variable value is: {?d}", .{self.idle_timeout});
            return error.FailedToUnwrap;
        }
    }
};
