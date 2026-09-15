const std = @import("std");

pub fn wgToServer(
    timer: *?std.atomic.Value(i64),
    packet_arrived: *std.atomic.Value(bool),
    io: std.Io,
    wg_sock: *std.Io.net.Socket,
    serv_sock: *std.Io.net.Socket,
    buf: []u8,
    servers: []std.Io.net.IpAddress,
    current_id: *std.atomic.Value(usize),
) !void {
    while (true) {

        // --- Handle WireGuard -> server ---
        if (std.Io.net.Socket.receive(wg_sock, io, buf[0..])) |recv| {
            std.log.debug("Received {d} bytes from WireGuard", .{recv.data.len});
            const packet = buf[0..recv.data.len];
            std.log.debug("Trying to send to {f}", .{&servers[current_id.load(.monotonic)]});
            if (std.Io.net.Socket.send(serv_sock, io, &servers[current_id.load(.acquire)], packet)) {
                // Unwrap timer optional
                if (timer.*) |*t| if (packet_arrived.load(.monotonic)) {
                    // Reset timer to sync threads and set packet_arrived state
                    t.store(std.Io.Clock.Timestamp.now(io, .awake).raw.toSeconds(), .monotonic);
                    packet_arrived.store(false, .monotonic);
                };
            } else |err| {
                std.log.err(
                    "Backend {f} failed: {t}",
                    .{ servers[current_id.load(.acquire)], err },
                );
            }
        } else |err| {
            return err;
        }
    }
}
pub fn serverToWg(
    packet_arrived: *std.atomic.Value(bool),
    io: std.Io,
    wg_sock: *std.Io.net.Socket,
    serv_sock: *std.Io.net.Socket,
    srv_buf: []u8,
    servers: []std.Io.net.IpAddress,
    current_id: *std.atomic.Value(usize),
    wg_addr: std.Io.net.IpAddress,
) !void {
    while (true) {

        // --- Handle server -> WireGuard ---
        if (std.Io.net.Socket.receive(serv_sock, io, srv_buf[0..])) |recv| {
            const addr = recv.from;
            std.log.debug("Received {d} bytes, server: {f}", .{ recv.data.len, addr });
            const packet = srv_buf[0..recv.data.len];
            const server = servers[current_id.load(.acquire)];
            if (!std.Io.net.IpAddress.eql(&addr, &server)) {
                std.log.warn("Wrong server responding: {f}\nCorrect server: {f}", .{ addr, server });
                // If Received packet comes before sending packet is out at startup, set the correct state and discard it
                packet_arrived.store(false, .monotonic);
                continue;
            }
            if (std.Io.net.Socket.send(wg_sock, io, &wg_addr, packet)) {
                // Confirm packet came from the server
                packet_arrived.store(true, .monotonic);
            } else |err| {
                std.log.err(
                    "Backend {f} failed: {t}",
                    .{ wg_addr, err },
                );
            }
        } else |err| {
            return err;
        }
    }
}
