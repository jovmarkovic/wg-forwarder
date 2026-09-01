const std = @import("std");
const EndpointPool = @import("endpoints.zig").EndpointPool;
const SwitcherState = @import("switcher.zig").SwitcherState;
const nowSeconds = @import("timestamp.zig").nowSeconds;

pub fn wgToServer(
    io: std.Io,
    switcher: *SwitcherState,
    wg_sock: *std.Io.net.Socket,
    serv_sock: *std.Io.net.Socket,
    buf: []u8,
    endpoints: *EndpointPool,
) !void {
    while (true) {

        // --- Handle WireGuard -> server ---
        if (std.Io.net.Socket.receive(wg_sock, io, buf[0..])) |recv| {
            std.log.debug("Received {d} bytes from WireGuard", .{recv.data.len});
            const packet = buf[0..recv.data.len];
            const endpoint = endpoints.currentAddr(io) orelse {
                std.log.warn("wgToServer failed to get server endpoint!", .{});
                continue;
            };
            std.log.debug("Trying to send to {f}", .{endpoint});
            if (std.Io.net.Socket.send(serv_sock, io, &endpoint, packet)) {
                switcher.last_send_at.store(nowSeconds(io), .monotonic);
            } else |err| {
                std.log.err("Backend send failed to: {f} {s}", .{ endpoint, @errorName(err) });
            }
        } else |err| {
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
            const endpoint = endpoints.currentAddr(io) orelse {
                std.log.warn("serverToWg failed to get server endpoint!", .{});
                continue;
            };
            if (!std.Io.net.IpAddress.eql(&addr, &endpoint)) {
                std.log.warn("Wrong server {f}; expected {f}", .{
                    addr, endpoint,
                });
                continue;
            }
            if (std.Io.net.Socket.send(wg_sock, io, &wg_addr, packet)) {
                // Confirm packet came from the server
                switcher.last_reply_at.store(nowSeconds(io), .monotonic);
            } else |err| {
                std.log.err("Backend send failed to: {f} {s}", .{ wg_addr, @errorName(err) });
            }
        } else |err| {
            return err;
        }
    }
}
