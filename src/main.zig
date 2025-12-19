const std = @import("std");
const cfg = @import("parser.zig");
const builtin = @import("builtin");
const ctime = @cImport(@cInclude("time.h"));

// Comptime logging level set to debug
pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};
var runtime_level = std.log.default_level;

// datetime formatting from C library, only compiled on MacOS
fn currentTime(w: *std.Io.Writer) !void {
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
        if (@intFromEnum(message_level) > @intFromEnum(runtime_level)) return;
        var buf: [64]u8 = undefined;
        const stderr, const ttyconfig = std.debug.lockStderrWriter(&buf);
        defer std.debug.unlockStderrWriter();

        ttyconfig.setColor(stderr, .reset) catch {};
        currentTime(stderr) catch return;
        stderr.writeAll(" ") catch return;

        ttyconfig.setColor(stderr, switch (message_level) {
            .err => .red,
            .warn => .yellow,
            .info => .green,
            .debug => .magenta,
        }) catch {};

        ttyconfig.setColor(stderr, .bold) catch {};
        stderr.writeAll("[") catch return;
        stderr.writeAll(message_level.asText()) catch return;
        stderr.writeAll("]") catch return;
        ttyconfig.setColor(stderr, .reset) catch {};
        ttyconfig.setColor(stderr, .dim) catch {};
        ttyconfig.setColor(stderr, .bold) catch {};
        if (scope != .default) {
            stderr.print("({s})", .{@tagName(scope)}) catch return;
        }
        stderr.writeAll(": ") catch return;
        ttyconfig.setColor(stderr, .reset) catch {};
        stderr.print(format ++ "\n", args) catch return;
        stderr.flush() catch return;
    } else {
        if (@intFromEnum(message_level) > @intFromEnum(runtime_level)) return;
        std.log.defaultLog(message_level, scope, format, args);
    }
}

fn switcher(
    io: std.Io,
    seconds: usize,
    timer: *?std.time.Timer,
    servers: []std.Io.net.IpAddress,
    current_id: *usize,
    packet_arrived: *bool,
) !void {
    // Unwrap timer  optional
    if (timer.*) |*t| {
        // Declare constants once before the main loop
        const duration: u64 = std.time.ns_per_s * seconds;

        while (true) {
            const elapsed = std.time.Timer.read(t);
            std.log.debug("Timer time elapsed: {d}", .{elapsed});
            std.log.debug("Timer time duration: {d}", .{duration});
            std.log.debug("Timer packet_arrived state: {}", .{packet_arrived.*});

            // Main check is if packet has arrived
            if (!packet_arrived.*) {
                // Second check is if enough time has passsed before switching
                if (elapsed < duration) {
                    try io.sleep(.fromNanoseconds(duration - elapsed), .awake);
                    continue;
                }
                const new_id = (current_id.* + 1) % servers.len;
                current_id.* = new_id;
                std.log.info("Switched servers endpoints!", .{});
                std.log.info("Current endpoint: {f}", .{&servers[current_id.*]});
                // Reset packet state
                packet_arrived.* = true;
            }
            // Reset timer to sync threads
            std.time.Timer.reset(t);
            try io.sleep(.fromNanoseconds(duration), .awake);
        }
    } else {
        std.log.err("Switcher got called but timer variable value is: {any}", .{timer});
        return error.FailedToUnwrap;
    }
}
fn wgToServer(
    timer: *?std.time.Timer,
    packet_arrived: *bool,
    io: std.Io,
    wg_sock: *std.Io.net.Socket,
    serv_sock: *std.Io.net.Socket,
    buf: []u8,
    servers: []std.Io.net.IpAddress,
    current_id: *usize,
) !void {
    while (true) {

        // --- Handle WireGuard -> server ---
        if (std.Io.net.Socket.receive(wg_sock, io, buf[0..])) |recv| {
            std.log.debug("Received {d} bytes from WireGuard", .{recv.data.len});
            const packet = buf[0..recv.data.len];
            std.log.debug("Trying to send to {f}", .{&servers[current_id.*]});
            if (std.Io.net.Socket.send(serv_sock, io, &servers[current_id.*], packet)) |_| {
                // Unwrap timer optional
                if (timer.*) |*t| if (packet_arrived.*) {
                    // Reset timer to sync threads and set packet_arrived state
                    std.time.Timer.reset(t);
                    packet_arrived.* = false;
                };
            } else |err| {
                std.log.err(
                    "Backend {f} failed: {any}",
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
    io: std.Io,
    wg_sock: *std.Io.net.Socket,
    serv_sock: *std.Io.net.Socket,
    srv_buf: []u8,
    servers: []std.Io.net.IpAddress,
    current_id: *usize,
    wg_addr: std.Io.net.IpAddress,
) !void {
    // Assign correct memory alignment so initPosix can work with it

    while (true) {

        // --- Handle server -> WireGuard ---
        if (std.Io.net.Socket.receive(serv_sock, io, srv_buf[0..])) |recv| {
            const addr = recv.from;
            std.log.debug("Received {d} bytes, server: {f}", .{ recv.data.len, addr });
            const packet = srv_buf[0..recv.data.len];
            const server = servers[current_id.*];
            if (!std.Io.net.IpAddress.eql(&addr, &server)) {
                std.log.warn("Wrong server responding: {f}\nCorrect server: {f}", .{ addr, server });
                // If Received packet comes before sending packet is out at startup, set the correct state and discard it
                packet_arrived.* = false;
                continue;
            }
            if (std.Io.net.Socket.send(wg_sock, io, &wg_addr, packet)) |_| {
                // Confirm packet came from the server
                packet_arrived.* = true;
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
pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const args = try std.process.argsAlloc(allocator);
    var io_init = std.Io.Threaded.init_single_threaded;
    const io = io_init.io();
    defer std.process.argsFree(allocator, args);

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
        std.log.info("Spawning switcher thread....", .{});
        timer = try std.time.Timer.start();
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
        &buf,
        servers,
        &current_id,
    });

    std.log.info("Spawning server listener....", .{});
    const server_thread = try std.Thread.spawn(.{}, serverToWg, .{
        &packet_arrived,
        io,
        &wg_sock,
        &serv_sock,
        &srv_buf,
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
