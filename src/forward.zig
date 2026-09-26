const std = @import("std");
const EndpointPool = @import("endpoints.zig").EndpointPool;
const SwitcherState = @import("switcher.zig").SwitcherState;
const nowMs = @import("timestamp.zig").nowMs;

pub fn wgToServer(
    io: std.Io,
    wg_addr: std.Io.net.IpAddress,
    switcher: *SwitcherState,
    wg_sock: *std.Io.net.Socket,
    serv_sock: *std.Io.net.Socket,
    buf: []u8,
    endpoints: *EndpointPool,
) !void {
    while (true) {

        // --- Handle WireGuard -> server ---
        if (std.Io.net.Socket.receive(wg_sock, io, buf[0..])) |recv| {
            const packet = buf[0..recv.data.len];
            std.log.debug("Received {d} bytes from WireGuard", .{recv.data.len});

            if (!std.Io.net.IpAddress.eql(&recv.from, &wg_addr)) {
                std.log.warn("Wrong client responding: {f} expected: {f}", .{ recv.from, wg_addr });
                continue;
            }

            const endpoint = endpoints.currentAddr() orelse {
                std.log.warn("wgToServer failed to get server endpoint!", .{});
                continue;
            };

            // Guard against keepalive from the client
            if (packet.len > 32) switcher.timerStart();
            std.log.debug("Trying to send to {f}", .{endpoint});
            std.Io.net.Socket.send(serv_sock, io, &endpoint, packet) catch |err| {
                std.log.err("Backend send to: {f} {t}", .{ endpoint, err });
            };
        } else |err| {
            std.log.err("Backend receive from: {f} {t}", .{ wg_sock.address, err });
            return err;
        }
    }
}

pub fn serverToWg(
    io: std.Io,
    wg_addr: std.Io.net.IpAddress,
    switcher: *SwitcherState,
    wg_sock: *std.Io.net.Socket,
    serv_sock: *std.Io.net.Socket,
    srv_buf: []u8,
    endpoints: *EndpointPool,
) !void {
    while (true) {

        // --- Handle server -> WireGuard ---
        if (std.Io.net.Socket.receive(serv_sock, io, srv_buf[0..])) |recv| {
            const addr = recv.from;
            std.log.debug("Received {d} bytes, server: {f}", .{ recv.data.len, addr });
            const packet = srv_buf[0..recv.data.len];
            const endpoint = endpoints.currentAddr() orelse {
                std.log.warn("serverToWg failed to get server endpoint!", .{});
                continue;
            };
            if (!std.Io.net.IpAddress.eql(&addr, &endpoint)) {
                std.log.warn("Wrong server responding: {f} expected: {f}", .{
                    addr, endpoint,
                });
                continue;
            }

            // Reset switcher state
            switcher.reset();
            std.Io.net.Socket.send(wg_sock, io, &wg_addr, packet) catch |err| {
                std.log.err("Backend send to: {f} {t}", .{ wg_addr, err });
            };
        } else |err| {
            std.log.err("Backend receive from: {f} {t}", .{ serv_sock.address, err });
            return err;
        }
    }
}
