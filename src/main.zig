const std = @import("std");
const parser = @import("parser.zig");
const builtin = @import("builtin");
const timestamp = @import("timestamp.zig");
const EndpointPool = @import("endpoints.zig").EndpointPool;
const SwitcherState = @import("switcher.zig").SwitcherState;
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
// Server_buffer hold data from server
var server_buffer: [9000]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    var dbga: std.heap.DebugAllocator(.{}) = .init;

    defer _ = dbga.deinit();

    const alloc = switch (builtin.mode) {
        .Debug => dbga.allocator(),
        else => std.heap.smp_allocator,
    };

    const args = try init.args.toSlice(alloc);
    defer alloc.free(args);

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
    var reader = try parser.readFile(io, alloc, path);
    defer reader.deinit(alloc);
    const config = reader.config();
    try parser.validate(config);

    if (config.log_level) |lvl| if (std.meta.stringToEnum(std.log.Level, lvl)) |level| {
        runtime_level = level;
    } else {
        std.log.err("Tried to set log level: {s}\nAvailable log levels: err, warn, info, debug", .{lvl});
        return error.UnknownLogLevel;
    } else {
        std.log.info("Using default log level: {t}", .{runtime_level});
    }

    // Format read endpoints
    var endpoints: EndpointPool = .{ .addr_family = config.address_family };
    defer endpoints.deinit(alloc);

    var bad_addr = false;
    for (config.switcher.endpoints, 0..) |ep, idx| {
        const addr = parser.parseHostPort(ep) catch |err| {
            std.log.err("config: switcher.endpoints[{d}] = \"{s}\": {t}", .{ idx, ep, err });
            bad_addr = true;
            continue;
        };
        endpoints.add(alloc, addr) catch |err| switch (err) {
            error.WrongFamily => {
                std.log.err("config: switcher.endpoints[{d}] = \"{s}\" is not {t}", .{
                    idx, ep, config.address_family,
                });
                bad_addr = true;
                continue;
            },
            error.Duplicate => {
                std.log.err("config: switcher.endpoints[{d}] = \"{s}\" is a duplicate", .{
                    idx, ep,
                });
                bad_addr = true;
                continue;
            },
            error.OutOfMemory => return err,
        };
    }
    if (bad_addr) return error.InvalidConfig;

    // Config checks for out_of_bounds, error should not be possible here
    if (!endpoints.setID(config.switcher.id)) return error.InvalidConfig;

    // WireGuard -> Forwarder
    const wg_listen_addr = try std.Io.net.IpAddress.parse(
        config.client_endpoint.address,
        config.client_endpoint.port,
    );
    try EndpointPool.matchFamily(wg_listen_addr, config.address_family);

    // Forwarder
    const fw_listen_addr = try std.Io.net.IpAddress.parse(
        config.forwarder_socket.address,
        config.forwarder_socket.port,
    );
    try EndpointPool.matchFamily(fw_listen_addr, config.address_family);

    // Server -> Forwarder
    const server_listen_addr = try std.Io.net.IpAddress.parse(
        config.server_socket.address orelse parser.anyAddress(config.address_family),
        config.server_socket.port,
    );
    try EndpointPool.matchFamily(server_listen_addr, config.address_family);

    // Listen for WireGuard (client) packets
    var wg_sock = try std.Io.net.IpAddress.bind(&fw_listen_addr, io, .{
        .mode = .dgram,
        .protocol = .udp,
    });

    // Listen for Server packets
    var serv_sock = try std.Io.net.IpAddress.bind(&server_listen_addr, io, .{
        .mode = .dgram,
        .protocol = .udp,
    });

    var switcher: SwitcherState = .{
        .idle_timeout = if (config.switcher.timer) |t| t else null,
        .endpoints = &endpoints,
    };
    var switcher_thread: ?std.Thread = null;

    // Comply with the switcher flag
    if (config.switcher.enabled) {
        std.log.info("Spawning switcher thread....", .{});
        switcher_thread = try std.Thread.spawn(.{}, SwitcherState.run, .{ &switcher, io });
    } else {
        std.log.info("Switching disabled, using endpoint derived form ID....", .{});
    }
    std.log.info("Spawning client listener....", .{});
    const client_thread = try std.Thread.spawn(.{}, wgToServer, .{
        io,
        &wg_sock,
        &serv_sock,
        &source_buffer,
        &endpoints,
        &switcher,
        wg_listen_addr,
    });

    std.log.info("Spawning server listener....", .{});
    const server_thread = try std.Thread.spawn(.{}, serverToWg, .{
        io,
        &wg_sock,
        &serv_sock,
        &server_buffer,
        &endpoints,
        &switcher,
        wg_listen_addr,
    });

    if (switcher_thread) |thread| {
        thread.join();
    }
    client_thread.join();
    server_thread.join();
}
