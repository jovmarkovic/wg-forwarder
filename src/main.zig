const std = @import("std");
const cfg = @import("parser.zig");
const builtin = @import("builtin");
const ctime = @cImport(@cInclude("time.h"));

// Comptime logging level set to debug
pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};
var log_level = std.log.default_level;

// datetime formatting from C library, only compiled on MacOS
fn formatCurrentTime(_: void, w: *std.Io.Writer) !void {
    const time = try w.writableSliceGreedy(64);
    var time_str: ctime.tm = undefined;
    var now: ctime.time_t = ctime.time(null);
    const timeinfo = ctime.localtime_r(&now, &time_str);
    const fmt = "%b %d %H:%M:%S"; // Example: "Oct 30 12:47:23"
    const time_len = ctime.strftime(time.ptr, time.len, fmt, timeinfo);
    w.advance(time_len);
}

// Function to set up runtime logging level
fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (builtin.os.tag == .macos) {
        var buf: [64]u8 = undefined;
        const w = std.debug.lockStderrWriter(&buf);
        defer std.debug.unlockStderrWriter();

        w.print("{f} [{t}]", .{ std.fmt.Alt(void, formatCurrentTime){ .data = {} }, message_level }) catch return;
        if (scope == .default) {
            w.writeAll(": ") catch return;
        } else {
            w.print("({t}): ", .{scope}) catch return;
        }
        w.print(format, args) catch return;
        w.writeAll("\n") catch return;
        w.flush() catch return;
    } else {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

fn switcher(
    seconds: usize,
    timer: *?std.time.Timer,
    servers: []std.net.Address,
    current_id: *usize,
    packet_arrived: *bool,
) !void {
    // Unwrap timer  optional
    if (timer.*) |*t| {
        // Declare constants once before the main loop
        const elapsed = std.time.Timer.read(t);
        const duration: u64 = std.time.ns_per_s * seconds;

        while (true) {
            std.log.debug("Timer time elapsed: {d}\n", .{elapsed});
            std.log.debug("Timer time duration: {d}\n", .{duration});
            std.log.debug("Timer packet_arrived state: {}\n", .{packet_arrived.*});

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
            std.time.Timer.reset(t);
            std.Thread.sleep(std.time.ns_per_s * seconds);
        }
    } else {
        std.log.err("Switcher got called but timer variable did not unwrap: {any}\n", .{timer});
        std.posix.exit(1);
    }
}
fn wgToServer(
    timer: *?std.time.Timer,
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
                // Unwrap timer optional
                if (timer.*) |*t| if (packet_arrived.*) {
                    // Reset timer to sync threads and set packet_arrived state
                    std.time.Timer.reset(t);
                    packet_arrived.* = false;
                };
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
    // Assign correct memory alignment so initPosix can work with it
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
            //  Converts other_addr to a correct struct that can be pretty formatted with {f}
            tmp_addr.* = other_addr.*;
            const addr = std.net.Address.initPosix(tmp_addr);
            std.log.debug("Received {d} bytes, server: {f}\n", .{ recv, addr });
            const packet = srv_buf[0..recv];
            const server = servers[current_id.*];
            if (!std.net.Address.eql(addr, server)) {
                std.log.warn("Wrong server responding: {f}\nCorrect server: {f}\n", .{ addr, server });
                // If Received packet comes before sending packet is out at startup, set the correct state and discard it
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
                // Confirm packet came from the server
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
    const allocator = std.heap.smp_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.log.err("Usage: {s} [-c] <config_path> \n", .{args[0]});
        return error.InvalidArgs;
    } else if (!std.mem.eql(u8, args[1], "-c")) {
        std.log.err("Usage: {s} [-c] <config_path> \n", .{args[0]});
        return error.InvalidArgs;
    }

    const path = args[2];
    const reader = try cfg.readFile(allocator, path);
    defer allocator.free(reader.buf);
    const config = reader.config;

    if (config.log_level) |lvl| if (std.meta.stringToEnum(std.log.Level, lvl)) |level| {
        log_level = level;
    } else {
        std.log.err("Unknown log level: {s}\nAvailable log levels: err, warn, info, debug\n", .{lvl});
        std.process.exit(1);
    } else {
        std.log.info("Using default log level: {s}\n", .{@tagName(log_level)});
    }
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

    // WireGuard -> Forwarder
    const wg_listen_addr = try std.net.Address.parseIp4(
        config.client_endpoint.address,
        config.client_endpoint.port,
    );

    // Forwarder
    const fw_listen_addr = try std.net.Address.parseIp4(
        config.forwarder_socket.address,
        config.forwarder_socket.port,
    );
    try std.posix.bind(
        wg_sock,
        &fw_listen_addr.any,
        fw_listen_addr.getOsSockLen(),
    );

    // Server -> Forwarder
    const server_listen_addr = try std.net.Address.parseIp4(
        config.server_socket.address,
        config.server_socket.port,
    );
    try std.posix.bind(
        serv_sock,
        &server_listen_addr.any,
        server_listen_addr.getOsSockLen(),
    );

    // Format read endpoints
    var servers = try allocator.alloc(std.net.Address, config.switcher.endpoints.len);
    defer allocator.free(servers);
    for (config.switcher.endpoints, 0..) |s, i| {
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
    var current_id: usize = config.switcher.id;

    // Buffers for holding packets. buf -> cleint; srv_buf -> server;
    var buf: [9000]u8 = undefined;
    var srv_buf: [9000]u8 = undefined;

    // Timer for swithing logic and syncing threads. If time exceeds duration (specified in sec), switch endpoints.
    // Block switcihing on every packet sent from server to client
    var timer: ?std.time.Timer = null;
    const time: ?usize = config.switcher.timer;
    var switcher_thread: ?std.Thread = null;
    var packet_arrived = true;

    // Comply with the switcher flag
    if (config.switcher.enabled) if (time) |seconds| {
        std.log.info("Spawning switcher thread....\n", .{});
        timer = try std.time.Timer.start();
        switcher_thread = try std.Thread.spawn(.{}, switcher, .{
            seconds,
            &timer,
            servers,
            &current_id,
            &packet_arrived,
        });
    } else {
        std.log.err("Switcher enabled but timer interval failed to unwrap: {any}\n", .{time});
        std.posix.exit(1);
    } else {
        std.log.info("Switching disabled, using endpoint derived form ID....\n", .{});
    }
    std.log.info("Spawning client listener....\n", .{});
    const client_thread = try std.Thread.spawn(.{}, wgToServer, .{
        &timer,
        &packet_arrived,
        wg_sock,
        serv_sock,
        &buf,
        &other_addr,
        &other_addrlen,
        servers,
        &current_id,
    });

    std.log.info("Spawning server listener....\n", .{});
    const server_thread = try std.Thread.spawn(.{}, serverToWg, .{
        &packet_arrived,
        wg_sock,
        serv_sock,
        &srv_buf,
        servers,
        &current_id,
        &other_addr,
        &other_addrlen,
        wg_listen_addr,
    });

    if (switcher_thread) |thread| {
        thread.join();
    }
    client_thread.join();
    server_thread.join();
}
