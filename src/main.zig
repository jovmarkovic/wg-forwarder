const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parser.zig");
const server = @import("server.zig");
const timestamp = @import("timestamp.zig");
const EndpointPool = @import("endpoints.zig").EndpointPool;
const SwitcherState = @import("switcher.zig").SwitcherState;
const serverToWg = @import("forward.zig").serverToWg;
const wgToServer = @import("forward.zig").wgToServer;

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
    var dbga: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = dbga.deinit();

    const alloc = switch (builtin.mode) {
        .Debug => dbga.allocator(),
        else => std.heap.smp_allocator,
    };

    const args = try init.args.toSlice(alloc);
    defer alloc.free(args);

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
    const reader = try parser.readFile(io, alloc, path);
    defer reader.deinit(alloc);
    const config = reader.config();
    try parser.validate(config);

    if (config.log_level) |lvl| if (std.meta.stringToEnum(std.log.Level, lvl)) |level| {
        runtime_level = level;
    } else {
        std.log.err("Tried to set log level: {s}\nAvailable log levels: err, warn, info, debug", .{lvl});
        return error.UnknownLogLevel;
    } else {
        std.log.info("Using default log level: {s}", .{@tagName(runtime_level)});
    }

    // Format read endpoints
    var endpoints: EndpointPool = .{ .addr_family = config.address_family };
    defer endpoints.deinit(alloc);

    var bad_addr = false;
    for (config.switcher.endpoints, 0..) |ep, idx| {
        const addr = parser.parseHostPort(ep) catch |err| {
            std.log.err("config: switcher.endpoints[{d}] = \"{s}\": {s}", .{
                idx, ep, @errorName(err),
            });
            bad_addr = true;
            continue;
        };
        const id = endpoints.add(io, alloc, addr) catch |err| switch (err) {
            error.WrongFamily => {
                std.log.err("config: switcher.endpoints[{d}] = \"{s}\" is not {s}", .{
                    idx, ep, @tagName(config.address_family),
                });
                bad_addr = true;
                continue;
            },
            error.Duplicate => {
                std.log.err("config: switcher.endpoints[{d}] = \"{s}\" is not {s}", .{
                    idx, ep, @tagName(config.address_family),
                });
                bad_addr = true;
                continue;
            },
            else => return err,
        };
        if (idx == config.switcher.id) _ = endpoints.setCurrent(io, id, addr);
    }
    if (bad_addr) return error.InvalidConfig;

    // WireGuard -> Forwarder
    const wg_listen_addr = try std.Io.net.IpAddress.parse(
        config.client_endpoint.address,
        config.client_endpoint.port,
    );
    _ = try EndpointPool.requireFamily(wg_listen_addr, config.address_family);

    // Forwarder
    const fw_listen_addr = try std.Io.net.IpAddress.parse(
        config.forwarder_socket.address,
        config.forwarder_socket.port,
    );
    _ = try EndpointPool.requireFamily(fw_listen_addr, config.address_family);

    // Listen for WireGuard (client) packets
    var wg_sock = try std.Io.net.IpAddress.bind(&fw_listen_addr, io, .{
        .mode = .dgram,
        .protocol = .udp,
    });

    // Endpoint -> Forwarder
    const endpoint_listen_addr = try std.Io.net.IpAddress.parse(
        config.server_socket.address orelse parser.anyAddress(config.address_family),
        config.server_socket.port,
    );
    _ = try EndpointPool.requireFamily(endpoint_listen_addr, config.address_family);

    // Listen for Endpoint packets
    var endpoint_sock = try std.Io.net.IpAddress.bind(&endpoint_listen_addr, io, .{
        .mode = .dgram,
        .protocol = .udp,
    });

    // Siwtcher struct holds all atomics
    var switcher: SwitcherState = .{
        .io = io,
        .idle_timeout = if (config.switcher.timer) |t| t else null,
        .endpoints = &endpoints,
    };
    // Deffering stop to run after joining other threads
    defer switcher.stop();

    var admin_server: ?std.Thread = null;
    if (config.admin_console.enabled) {
        std.log.info("Spawning admin server thread....", .{});
        admin_server = try std.Thread.spawn(.{}, server.adminServer, .{
            io,
            alloc,
            config.admin_console.address orelse parser.loopback(config.address_family),
            config.admin_console.port,
            &endpoints,
            &switcher,
        });
    }
    // Comply with the switcher flag
    if (config.switcher.enabled) {
        _ = try switcher.startOrPlay();
    } else {
        std.log.info("Switching disabled, using endpoint derived form ID....", .{});
    }
    std.log.info("Spawning client listener....", .{});
    const client_thread = try std.Thread.spawn(.{}, wgToServer, .{
        io,
        &switcher,
        &wg_sock,
        &endpoint_sock,
        &source_buffer,
        &endpoints,
    });

    std.log.info("Spawning server listener....", .{});
    const endpoint_thread = try std.Thread.spawn(.{}, serverToWg, .{
        io,
        wg_listen_addr,
        &switcher,
        &wg_sock,
        &endpoint_sock,
        &endpoint_buffer,
        &endpoints,
    });

    // Thread joining
    if (admin_server) |t| {
        t.join();
        std.log.info("Stopping admin server thread....", .{});
    }
    client_thread.join();
    std.log.info("Stopping client listener....", .{});
    endpoint_thread.join();
    std.log.info("Stopping server listener....", .{});
}
