const std = @import("std");

//TODO: handle_sigint
// fn handle_sigint(_: c_int) callconv(.C) void {
//     // Just mark that Ctrl+C was pressed
//     std.atomic.Atomic(bool).init(false).store(true, .SeqCst);
// }
fn switchServer(
    timer: *std.time.Timer,
    servers: []std.net.Address,
    current_id: *usize,
    packet_arrived: *bool,
) !void {
    while (true) {
        const elapsed = std.time.Timer.read(timer);
        const duration: u64 = std.time.ns_per_s * 15;
        std.log.debug("Time elapsed: {d}\n", .{elapsed});
        std.log.debug("Time duration: {d}\n", .{duration});
        std.log.debug("Time packet_arrived: {}\n", .{packet_arrived.*});

        // Main check is if packet has arrived
        if (!packet_arrived.*) {
            // Second check is if enough time has passsed before switching
            if (elapsed < duration) {
                std.Thread.sleep(duration - elapsed);
                continue;
            }
            const new_id = (current_id.* + 1) % servers.len;
            current_id.* = new_id;
            std.log.info("Switched servers endpoints!\n", .{});
            std.log.info("Current endpoint: {f}\n", .{&servers[current_id.*]});
            // Reset packet state
            packet_arrived.* = true;
        }
        // Reset timer to sync threads
        std.time.Timer.reset(timer);
        std.Thread.sleep(std.time.ns_per_s * 15);
    }
}
fn wgToServer(
    timer: *std.time.Timer,
    packet_arrived: *bool,
    wg_sock: c_int,
    serv_sock: c_int,
    buf: []u8,
    other_addr: *std.posix.sockaddr,
    other_addrlen: *std.posix.socklen_t,
    servers: []std.net.Address,
    current_id: *usize,
) !void {
    while (true) {

        // --- Handle WireGuard -> server ---
        if (std.posix.recvfrom(
            wg_sock,
            buf[0..],
            0,
            other_addr,
            other_addrlen,
        )) |recv| {
            std.log.debug("Received {d} bytes from WireGuard\n", .{recv});
            const packet = buf[0..recv];
            std.log.debug("Trying to send to {f}\n", .{&servers[current_id.*]});
            if (std.posix.sendto(
                serv_sock,
                packet,
                0,
                &servers[current_id.*].any,
                servers[current_id.*].getOsSockLen(),
            )) |_| {
                //Reset packet_arrived flag
                if (packet_arrived.*) {
                    // Reset timer to sync threads
                    std.time.Timer.reset(timer);
                    packet_arrived.* = false;
                }
            } else |err| {
                std.log.err(
                    "Backend {f} failed: {any}\n",
                    .{ servers[current_id.*], err },
                );
            }
        } else |err| {
            return err;
        }
    }
}
fn serverToWg(
    packet_arrived: *bool,
    wg_sock: c_int,
    serv_sock: c_int,
    srv_buf: []u8,
    servers: []std.net.Address,
    current_id: *usize,
    other_addr: *std.posix.sockaddr,
    other_addrlen: *std.posix.socklen_t,
    wg_addr: std.net.Address,
) !void {
    const tmp_addr: *align(4) std.posix.sockaddr = @alignCast(other_addr);

    while (true) {

        // --- Handle server -> WireGuard ---
        if (std.posix.recvfrom(
            serv_sock,
            srv_buf[0..],
            0,
            other_addr,
            other_addrlen,
        )) |recv| {
            const addr = std.net.Address.initPosix(tmp_addr);
            tmp_addr.* = other_addr.*;
            std.log.debug("Received {d} bytes, server: {f}\n", .{ recv, addr });
            const packet = srv_buf[0..recv];
            const server = servers[current_id.*];
            std.log.debug("Correct server: {f}\n", .{server});
            if (!std.net.Address.eql(addr, server)) {
                std.log.warn("Wrong server responding, it should be: {f}\n", .{server});
                // If Received packet comes before sending packet is out at startup, set the correct state
                packet_arrived.* = false;
                continue;
            }
            if (std.posix.sendto(
                wg_sock,
                packet,
                0,
                &wg_addr.any,
                wg_addr.getOsSockLen(),
            )) |_| {
                // Confirm packet came from server
                packet_arrived.* = true;
            } else |err| {
                std.log.err(
                    "Backend {f} failed: {any}\n",
                    .{ wg_addr, err },
                );
            }
        } else |err| {
            return err;
        }
    }
}
pub fn main() !void {
    // Define memory allocator and handle sig-INT
    const allocator = std.heap.smp_allocator;
    //TODO: Handle sig-INT
    // const sig = std.posix.SIG;
    // try std.posix.sigaction(sig.INT, &std.posix.Sigaction{
    //     .handler = .{ .handler = handle_sigint },
    //     .mask = std.posix.empty_sigset,
    //     .flags = 0,
    // }, null);

    var other_addr: std.posix.sockaddr = undefined;
    var other_addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

    // Listen for WireGuard (client) packets
    const wg_sock = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM,
        std.posix.IPPROTO.UDP,
    );
    defer std.posix.close(wg_sock);

    // Listen for Server packets
    const serv_sock = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM,
        std.posix.IPPROTO.UDP,
    );
    defer std.posix.close(serv_sock);

    // WireGuard -> Proxy
    const wg_listen_port: u16 = 51821;
    const wg_listen_addr = try std.net.Address.parseIp4("127.0.0.1", wg_listen_port);
    // Proxy
    const proxy_listen_port: u16 = 61821;
    const proxy_listen_addr = try std.net.Address.parseIp4("127.0.0.1", proxy_listen_port);
    try std.posix.bind(
        wg_sock,
        &proxy_listen_addr.any,
        proxy_listen_addr.getOsSockLen(),
    );

    // Proxy -> Server
    const server_listen_port: u16 = 8921;
    const server_listen_addr = try std.net.Address.parseIp4("0.0.0.0", server_listen_port);
    try std.posix.bind(
        serv_sock,
        &server_listen_addr.any,
        server_listen_addr.getOsSockLen(),
    );
    //TODO: Make it file readable
    const server_endpoints = [_][]const u8{
        "192.168.1.4:8921",
        "100.116.14.17:8921",
    };

    // Format read endpoints
    var servers: [server_endpoints.len]std.net.Address = undefined;
    for (server_endpoints, 0..) |s, i| {
        var split: std.ArrayList([]const u8) = .empty;
        defer split.deinit(allocator);
        var iter = std.mem.splitScalar(u8, s, ':');
        while (iter.next()) |part| {
            try split.append(allocator, part);
        }
        const ip = split.items[0];
        const port = try std.fmt.parseInt(u16, split.items[1], 10);
        servers[i] = try std.net.Address.parseIp4(ip, port);
    }
    // Set default server ID
    var current_id: usize = 1;

    // Buffers for holding packets. buf -> cleint; srv_buf -> server;
    var buf: [9000]u8 = undefined;
    var srv_buf: [9000]u8 = undefined;

    // Timer for swithing logic and syncing threads. If time exceeds 20 sec, switch servers.
    // Block switcihing on every packet sent from server to client
    var timer = try std.time.Timer.start();
    var packet_arrived = true;
    std.log.info("Spawning timer_thread....\n", .{});
    const timer_thread = try std.Thread.spawn(.{}, switchServer, .{
        &timer,
        &servers,
        &current_id,
        &packet_arrived,
    });
    std.log.info("Spawning client listener....\n", .{});
    const client_thread = try std.Thread.spawn(.{}, wgToServer, .{
        &timer,
        &packet_arrived,
        wg_sock,
        serv_sock,
        &buf,
        &other_addr,
        &other_addrlen,
        &servers,
        &current_id,
    });
    std.log.info("Spawning server listener....\n", .{});
    const server_thread = try std.Thread.spawn(.{}, serverToWg, .{
        &packet_arrived,
        wg_sock,
        serv_sock,
        &srv_buf,
        &servers,
        &current_id,
        &other_addr,
        &other_addrlen,
        wg_listen_addr,
    });

    timer_thread.join();
    client_thread.join();
    server_thread.join();
}
