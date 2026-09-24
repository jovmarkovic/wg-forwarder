const std = @import("std");
const EndpointPool = @import("endpoints.zig").EndpointPool;
const SwitcherState = @import("switcher.zig").SwitcherState;
const nowMs = @import("timestamp.zig").nowMs;

pub fn wgToServer(
    io: std.Io,
    wg_sock: *std.Io.net.Socket,
    serv_sock: *std.Io.net.Socket,
    buf: []u8,
    servers: *EndpointPool,
    switcher: *SwitcherState,
    wg_addr: std.Io.net.IpAddress,
) !void {
    while (true) {

        // --- Handle WireGuard -> server ---
        if (std.Io.net.Socket.receive(wg_sock, io, buf[0..])) |recv| {
            const packet = buf[0..recv.data.len];
            std.log.debug("Received {d} bytes from WireGuard", .{recv.data.len});

            if (!std.Io.net.IpAddress.eql(&recv.from, &wg_addr)) {
                std.log.warn("Wrong client responding: {f}\nCorrect client: {f}", .{ recv.from, wg_addr });
                continue;
            }
            const addr = servers.currentAddr() orelse {
                std.log.warn("wgToServer: currentAddr not found", .{});
                continue;
            };

            // Guard against keepalive packet from the client
            if (packet.len > 32) switcher.timerStart(io);
            std.log.debug("Trying to send to {f}", .{addr});
            std.Io.net.Socket.send(serv_sock, io, &addr, packet) catch |err| {
                std.log.err("Backend send to: {f} failed: {t}", .{ addr, err });
            };
        } else |err| {
            std.log.err(
                "Backend receive from: {f} failed: {t}",
                .{ wg_sock.address, err },
            );
            return err;
        }
    }
}

pub fn serverToWg(
    io: std.Io,
    wg_sock: *std.Io.net.Socket,
    serv_sock: *std.Io.net.Socket,
    srv_buf: []u8,
    servers: *EndpointPool,
    switcher: *SwitcherState,
    wg_addr: std.Io.net.IpAddress,
) !void {
    while (true) {

        // --- Handle server -> WireGuard ---
        if (std.Io.net.Socket.receive(serv_sock, io, srv_buf[0..])) |recv| {
            const addr = recv.from;
            const server = servers.currentAddr() orelse {
                std.log.warn("serverToWg: currentAddr not found", .{});
                continue;
            };
            const packet = srv_buf[0..recv.data.len];
            std.log.debug("Received {d} bytes, server: {f}", .{ recv.data.len, addr });

            if (!std.Io.net.IpAddress.eql(&addr, &server)) {
                std.log.warn("Wrong server responding: {f}\nCorrect server: {f}", .{ addr, server });
                // If Received packet comes before sending packet is out at startup, discard it
                continue;
            }
            // Reset the state on packet arrived
            switcher.reset(io);
            std.log.debug("Trying to send to {f}", .{wg_addr});
            std.Io.net.Socket.send(wg_sock, io, &wg_addr, packet) catch |err| {
                std.log.err(
                    "Backend send to :{f} failed: {t}",
                    .{ wg_addr, err },
                );
            };
        } else |err| {
            std.log.err(
                "Backend receive from: {f} failed: {t}",
                .{ serv_sock.address, err },
            );
            return err;
        }
    }
}
