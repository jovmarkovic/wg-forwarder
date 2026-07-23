const std = @import("std");
const cfg = @import("parser.zig");
const builtin = @import("builtin");
const timestamp = @import("timestamp.zig");
const lib = @import("root.zig");
const server = @import("server.zig");

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
        stderr.writer.print("{f} UTC ", .{ts.fmt(.syslog)}) catch {};
    }
    // Same return that std.log.defaultLog() does
    return std.log.defaultLogFileTerminal(level, scope, format, args, stderr) catch {};
}

// Source_buffer holds data from cleint
var source_buffer: [9000]u8 = undefined;
// Endpoint_buffer hold data from endpoint
var endpoint_buffer: [9000]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    var dbga: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbga.deinit();

    const allocator = switch (builtin.mode) {
        .Debug => dbga.allocator(),
        else => std.heap.smp_allocator,
    };

    const args = try init.args.toSlice(allocator);
    defer allocator.free(args);

    var io_init: std.Io.Threaded = .init_single_threaded;
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
        .mode = .dgram,
        .protocol = .udp,
    });

    // Endpoint -> Forwarder
    const endpoint_listen_addr = try std.Io.net.IpAddress.parse(
        config.server_socket.address,
        config.server_socket.port,
    );
    // Listen for Endpoint packets
    var endpoint_sock = try std.Io.net.IpAddress.bind(&endpoint_listen_addr, io, .{
        .mode = .dgram,
        .protocol = .udp,
    });

    // Format read endpoints
    var endpoints: lib.SafeEndpointList = .{};
    defer endpoints.deinit(allocator);
    for (config.switcher.endpoints) |s| {
        var split: std.ArrayList([]const u8) = .empty;
        defer split.deinit(allocator);
        var iter = std.mem.splitScalar(u8, s, ':');
        while (iter.next()) |part| {
            try split.append(allocator, part);
        }
        const ip = split.items[0];
        const port = try std.fmt.parseInt(u16, split.items[1], 10);
        const addr = try std.Io.net.IpAddress.parse(ip, port);
        try endpoints.add(io, allocator, addr);
    }

    // Set default server ID
    var current_id: std.atomic.Value(usize) = .init(config.switcher.id);

    // Siwtcher struct holds all atomics
    var switcher: lib.SwitcherState = .{
        .is_running = .init(config.switcher.enabled),
        .io = io,
        .duration = .init(@intCast(config.switcher.timer)),
        .timer = .init(std.Io.Clock.Timestamp.now(io, .awake).raw.toSeconds()),
        .packet_arrived = .init(true),
        .endpoints = &endpoints,
        .current_id = &current_id,
    };
    // Deffering stop to run after joining other threads
    defer switcher.stop();

    var admin_server: ?std.Thread = null;
    if (config.admin_console.enabled) {
        std.log.info("Spawning admin server thread....", .{});
        admin_server = try std.Thread.spawn(.{}, server.adminServer, .{
            io,
            allocator,
            config.admin_console.address,
            config.admin_console.port,
            &endpoints,
            &current_id,
            &switcher,
        });
    }
    // Comply with the switcher flag
    if (config.switcher.enabled) {
        std.log.info("Spawning switcher thread....", .{});
        try switcher.start();
    } else {
        std.log.info("Switching disabled, using endpoint derived form ID....", .{});
    }
    std.log.info("Spawning client listener....", .{});
    const client_thread = try std.Thread.spawn(.{}, lib.wgToServer, .{
        io,
        &switcher,
        &wg_sock,
        &endpoint_sock,
        &source_buffer,
        &endpoints,
        &current_id,
    });

    std.log.info("Spawning server listener....", .{});
    const endpoint_thread = try std.Thread.spawn(.{}, lib.serverToWg, .{
        io,
        wg_listen_addr,
        &switcher,
        &wg_sock,
        &endpoint_sock,
        &endpoint_buffer,
        &endpoints,
        &current_id,
    });

    // Thread joining
    if (admin_server) |t| {
        t.join();
    }
    client_thread.join();
    endpoint_thread.join();
}
