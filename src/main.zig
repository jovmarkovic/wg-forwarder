const std = @import("std");
const cfg = @import("parser.zig");
const builtin = @import("builtin");
const timestamp = @import("timestamp.zig");
const switcher = @import("switcher.zig").switcher;
const wgToServer = @import("forward.zig").wgToServer;
const serverToWg = @import("forward.zig").serverToWg;

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
    if (@backingInt(level) > @backingInt(runtime_level)) return;

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
        stderr.writer.print("{f} UTC ", .{ts.fmt(.syslog)}) catch {};
    }
    // Same return that std.log.defaultLog() does
    return std.log.defaultLogFileTerminal(level, scope, format, args, stderr) catch {};
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
        std.log.info("Using default log level: {t}", .{runtime_level});
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
