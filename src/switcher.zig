const std = @import("std");

pub fn switcher(
    io: std.Io,
    seconds: isize,
    timer: *?std.atomic.Value(i64),
    servers: []std.Io.net.IpAddress,
    current_id: *std.atomic.Value(usize),
    packet_arrived: *std.atomic.Value(bool),
) !void {
    // Unwrap timer  optional
    if (timer.*) |*t| {
        // Declare constants once before the main loop
        const duration = seconds;

        while (true) {
            const now = std.Io.Clock.Timestamp.now(io, .awake).raw.toSeconds();
            const elapsed = now - t.load(.monotonic);
            std.log.debug("Timer time elapsed: {d}", .{elapsed});
            std.log.debug("Timer time duration: {d}", .{duration});
            std.log.debug("Timer packet_arrived state: {}", .{packet_arrived.load(.monotonic)});

            // Main check is if packet has arrived
            if (!packet_arrived.load(.monotonic)) {
                // Second check is if enough time has passsed before switching
                if (elapsed < duration) {
                    try io.sleep(.fromSeconds(duration - elapsed), .awake);
                    continue;
                }
                const new_id = (current_id.load(.monotonic) + 1) % servers.len;
                current_id.store(new_id, .release);
                std.log.info("Switched servers endpoints!", .{});
                std.log.info("Current endpoint: {f}", .{&servers[current_id.load(.monotonic)]});
                // Reset packet state
                packet_arrived.store(true, .monotonic);
            }
            // Reset time to sync threads
            t.store(std.Io.Clock.Timestamp.now(io, .awake).raw.toSeconds(), .monotonic);
            try io.sleep(.fromSeconds(duration), .awake);
        }
    } else {
        std.log.err("Switcher got called but timer variable value is: {any}", .{timer});
        return error.FailedToUnwrap;
    }
}
