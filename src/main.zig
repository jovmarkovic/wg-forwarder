const std = @import("std");
const cfg = @import("parser.zig");
const builtin = @import("builtin");
const timestamp = @import("timestamp.zig");

// Comptime logging level set to debug
pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};
var runtime_level = std.log.default_level;

// Function to set up runtime logging level
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Custom check for changing runtime logging
    if (@intFromEnum(level) > @intFromEnum(runtime_level)) return;

    // Copy-pasted implemetntion of defaultLog() from std.log
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();

    if (builtin.os.tag == .macos) {
        // Added timestamp to output
        const ts = timestamp.Time.create(io);
        stderr.writer.print("{f} ", .{ts.fmt(.syslog)}) catch {};
    }
    // Same return that std.log.defaultLog() does
    return std.log.defaultLogFileTerminal(level, scope, format, args, stderr) catch {};
}

fn switcher(
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
fn wgToServer(
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
                    "Backend {f} failed: {any}",
                    .{ servers[current_id.load(.acquire)], err },
                );
            }
        } else |err| {
            return err;
        }
    }
}
fn serverToWg(
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
                    "Backend {f} failed: {any}",
                    .{ wg_addr, err },
                );
            }
        } else |err| {
            return err;
        }
    }
}

// Source_buffer holds data from cleint
var source_buffer: [9000]u8 = undefined;
// Server_buffer hold data from server
var server_buffer: [9000]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;

    const args = try init.args.toSlice(allocator);
    defer allocator.free(args);

    var io_init = std.Io.Threaded.init_single_threaded;
    defer io_init.deinit();

    const io = io_init.io();

    if (args.len != 3) {
        std.debug.print("Usage: {s} [-c] <config_path>\n", .{args[0]});
        return error.InvalidArgs;
    } else if (!std.mem.eql(u8, args[1], "-c")) {
        std.debug.print("Usage: {s} [-c] <config_path>\n", .{args[0]});
        return error.InvalidArgs;
    }

    const path = args[2];
    const reader = try cfg.readFile(io, allocator, path);
    defer allocator.free(reader.buf);
    const config = reader.config;

    if (config.log_level) |lvl| if (std.meta.stringToEnum(std.log.Level, lvl)) |level| {
        runtime_level = level;
    } else {
        std.log.err("Tried to set log level: {s}\nAvailable log levels: err, warn, info, debug", .{lvl});
        return error.UnknownLogLevel;
    } else {
        std.log.info("Using default log level: {s}", .{@tagName(runtime_level)});
    }

    // WireGuard -> Forwarder
    const wg_listen_addr = try std.Io.net.IpAddress.parse(
        config.client_endpoint.address,
        config.client_endpoint.port,
    );

    // Forwarder
    const fw_listen_addr = try std.Io.net.IpAddress.parse(
        config.forwarder_socket.address,
        config.forwarder_socket.port,
    );

    // Listen for WireGuard (client) packets
    var wg_sock = try std.Io.net.IpAddress.bind(&fw_listen_addr, io, .{
        .ip6_only = false,
        .mode = .dgram,
        .protocol = .udp,
    });

    // Server -> Forwarder
    const server_listen_addr = try std.Io.net.IpAddress.parse(
        config.server_socket.address,
        config.server_socket.port,
    );
    // Listen for Server packets
    var serv_sock = try std.Io.net.IpAddress.bind(&server_listen_addr, io, .{
        .ip6_only = false,
        .mode = .dgram,
        .protocol = .udp,
    });

    // Format read endpoints
    var servers = try allocator.alloc(std.Io.net.IpAddress, config.switcher.endpoints.len);
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
        servers[i] = try std.Io.net.IpAddress.parse(ip, port);
    }

    // Set default server ID
    var current_id = std.atomic.Value(usize).init(config.switcher.id);

    // Timer for swithing logic and syncing threads. If time exceeds duration (specified in sec), switch endpoints.
    // Block switcihing on every packet sent from server to client
    var timer: ?std.atomic.Value(i64) = null;
    const time: ?isize = if (config.switcher.timer) |t|
        @intCast(@min(t, std.math.maxInt(isize)))
    else
        null;

    var switcher_thread: ?std.Thread = null;
    var packet_arrived = std.atomic.Value(bool).init(true);

    // Comply with the switcher flag
    if (config.switcher.enabled) if (time) |seconds| {
        std.log.info("Spawning switcher thread....", .{});
        timer = std.atomic.Value(i64).init(std.Io.Clock.Timestamp.now(io, .awake).raw.toSeconds());
        switcher_thread = try std.Thread.spawn(.{}, switcher, .{
            io,
            seconds,
            &timer,
            servers,
            &current_id,
            &packet_arrived,
        });
    } else {
        std.log.debug("Switcher enabled but timer interval value is: {any}", .{time});
        return error.FailedToUnwrap;
    } else {
        std.log.info("Switching disabled, using endpoint derived form ID....", .{});
    }
    std.log.info("Spawning client listener....", .{});
    const client_thread = try std.Thread.spawn(.{}, wgToServer, .{
        &timer,
        &packet_arrived,
        io,
        &wg_sock,
        &serv_sock,
        &source_buffer,
        servers,
        &current_id,
    });

    std.log.info("Spawning server listener....", .{});
    const server_thread = try std.Thread.spawn(.{}, serverToWg, .{
        &packet_arrived,
        io,
        &wg_sock,
        &serv_sock,
        &server_buffer,
        servers,
        &current_id,
        wg_listen_addr,
    });

    if (switcher_thread) |thread| {
        thread.join();
    }
    client_thread.join();
    server_thread.join();
}
