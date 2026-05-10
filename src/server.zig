const std = @import("std");
const lib = @import("root.zig");

const Context = enum {
    global,
    endpoint,
    switcher,
};

const GlobalCmd = enum {
    const Self = @This();
    help,
    @"?",
    list,
    status,
    info,
    switcher,
    endpoint,
    exit,
    quit,
    q,

    // Helper to turn the string into this enum
    fn from(s: []const u8) ?Self {
        return std.meta.stringToEnum(Self, s);
    }
};

const EndpointCmd = enum {
    const Self = @This();
    add,
    remove,
    rm,
    set,
    find,
    @"return",
    ret,

    // Helper to turn the string into this enum
    fn from(s: []const u8) ?Self {
        return std.meta.stringToEnum(Self, s);
    }
};
const SwitcherCmd = enum {
    const Self = @This();
    play,
    pause,
    kill,
    timer,
    @"return",
    ret,

    // Helper to turn the string into this enum
    fn from(s: []const u8) ?Self {
        return std.meta.stringToEnum(Self, s);
    }
};

pub fn adminServer(
    io: std.Io,
    gpa: std.mem.Allocator,
    ip: []const u8,
    port: u16,
    endpoints: *lib.SafeEndpointList,
    current_id: *std.atomic.Value(usize),
    switcher: *lib.SwitcherState,
) !void {
    const address = try std.Io.net.IpAddress.parse(ip, port);
    var server = try std.Io.net.IpAddress.listen(&address, io, .{
        .mode = .stream,
        .reuse_address = true,
    });

    while (true) {
        // Reset state for every new session
        var ctx: Context = .global;
        // Wait for an admin to connect (e.g., via nc or telnet )
        var conn = try server.accept(io);
        std.log.info("Admin connected from: {f}", .{conn.socket.address});
        defer {
            conn.socket.close(io);
            std.log.info("Admin session ended for: {f}", .{conn.socket.address});
        }

        const welcome = "WG-Forwarder Admin Console\nType in help or ? for more information.\n> ";
        try conn.socket.send(io, &conn.socket.address, welcome);

        var buf: [128]u8 = undefined;
        // Session loop
        while (true) {
            if (conn.socket.receive(io, &buf)) |recv| {
                processInput(
                    io,
                    gpa,
                    conn,
                    recv.data,
                    &ctx,
                    endpoints,
                    current_id,
                    switcher,
                ) catch |err| switch (err) {
                    error.Exit => {
                        // Convert error.Exit to graceful shutdown of the session
                        conn.socket.send(io, &conn.socket.address, "Bye!\n") catch {};
                        break;
                    },
                    else => return err,
                };
            } else |err| switch (err) {
                // Ignore these types of errors, they are handled by reply() in processInput()
                error.ConnectionResetByPeer, error.Canceled => {
                    break;
                },
                else => return err,
            }
        }
    }
}

/// Process admin_console input
fn processInput(
    io: std.Io,
    gpa: std.mem.Allocator,
    conn: std.Io.net.Stream,
    data: []u8,
    ctx: *Context,
    endpoints: *lib.SafeEndpointList,
    current_id: *std.atomic.Value(usize),
    switcher: *lib.SwitcherState,
) !void {
    var msg_buf: [128]u8 = undefined;
    var iter = std.mem.tokenizeAny(u8, data, " \r\n\t");

    switch (ctx.*) {
        .global => try handleGlobal(
            io,
            conn,
            &msg_buf,
            &iter,
            ctx,
            switcher,
            endpoints,
            current_id,
        ),
        .endpoint => try handleEndpoint(
            io,
            gpa,
            &msg_buf,
            conn,
            &iter,
            ctx,
            switcher,
            endpoints,
            current_id,
        ),
        .switcher => try handleSwitcher(
            io,
            &msg_buf,
            conn,
            &iter,
            ctx,
            switcher,
            endpoints,
            current_id,
        ),
    }
}

/// Helper for catching errors
fn reply(io: std.Io, conn: std.Io.net.Stream, msg: []const u8) void {
    conn.socket.send(io, &conn.socket.address, msg) catch |err| {
        std.log.warn("Admin reply failed: {s}", .{@errorName(err)});
    };
}

/// Helper for "newline" print
fn printPrompt(io: std.Io, conn: std.Io.net.Stream, ctx: Context) void {
    const msg = switch (ctx) {
        .global => "> ",
        .endpoint => "(endpoint)> ",
        .switcher => "(switcher)> ",
    };
    conn.socket.send(io, &conn.socket.address, msg) catch {};
}

fn handleGlobal(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    iter: *std.mem.TokenIterator(u8, .any),
    ctx: *Context,
    switcher: *lib.SwitcherState,
    endpoints: *lib.SafeEndpointList,
    current_id: *std.atomic.Value(usize),
) !void {
    const help_msg =
        \\Available Global Commands:
        \\  help (?)        - Show this message
        \\  list            - List all available endpoints
        \\  status (info)   - Show switcher status and current server info
        \\  switcher        - Interactively manage switcher
        \\  endpoint        - Interactively manage endpoint
        \\  exit/quit (q)   - Close the admin connection
        \\
    ;
    const raw_cmd = iter.next() orelse {
        printPrompt(io, conn, ctx.*);
        return;
    };

    // Use your GlobalCmd enum helper
    const cmd = GlobalCmd.from(raw_cmd) orelse {
        reply(io, conn, "Unknown command!\n");
        printPrompt(io, conn, ctx.*);
        return;
    };

    switch (cmd) {
        .exit, .quit, .q => return error.Exit,
        .help, .@"?" => reply(io, conn, help_msg),
        .list => try listEndpoints(io, conn, msg_buf, endpoints),
        .status, .info => try showStatus(
            io,
            conn,
            msg_buf,
            switcher,
            endpoints,
            current_id,
        ),
        .switcher => ctx.* = .switcher,
        .endpoint => ctx.* = .endpoint,
    }
    // After every successful command:
    printPrompt(io, conn, ctx.*);
}

fn handleEndpoint(
    io: std.Io,
    gpa: std.mem.Allocator,
    msg_buf: []u8,
    conn: std.Io.net.Stream,
    iter: *std.mem.TokenIterator(u8, .any),
    ctx: *Context,
    switcher: *lib.SwitcherState,
    endpoints: *lib.SafeEndpointList,
    current_id: *std.atomic.Value(usize),
) !void {
    const help_msg =
        \\Available Endpoint Commands:
        \\  help (?)        - Show this message
        \\  list            - List all available endpoints
        \\  add ip:port     - Adds one or more endpoints
        \\                      Use 'ip:port ip:port' with out qotes to add multiple
        \\  remove (rm) <n> - Remove endpoint by ID
        \\  set <n>         - Manually set the active endpoint ID
        \\  find ip:port    - Find ID from the address 
        \\  status (info)   - Show switcher status and current server info
        \\  switcher        - Interactively manage switcher 
        \\  return (ret)    - Return to global session state
        \\  exit/quit (q)   - Close the admin connection
        \\
    ;

    const raw_cmd = iter.next() orelse {
        printPrompt(io, conn, ctx.*);
        return;
    };

    if (GlobalCmd.from(raw_cmd)) |cmd| {
        switch (cmd) {
            .exit, .quit, .q => return error.Exit,
            .help, .@"?" => reply(io, conn, help_msg),
            .list => try listEndpoints(io, conn, msg_buf, endpoints),
            .status, .info => try showStatus(
                io,
                conn,
                msg_buf,
                switcher,
                endpoints,
                current_id,
            ),
            .switcher => ctx.* = .switcher,
            .endpoint => {}, // Ignore, already in endpoint state
        }

        printPrompt(io, conn, ctx.*);
        return;
    }

    if (EndpointCmd.from(raw_cmd)) |cmd| {
        switch (cmd) {
            .add => try addEndpoint(
                io,
                gpa,
                conn,
                msg_buf,
                iter,
                endpoints,
            ),
            .remove, .rm => try removeEndpoint(
                io,
                conn,
                msg_buf,
                iter,
                endpoints,
                current_id,
            ),
            .set => try setEndpoint(
                io,
                conn,
                msg_buf,
                iter,
                endpoints,
                current_id,
            ),
            .find => try findID(
                io,
                conn,
                msg_buf,
                iter,
                endpoints,
            ),
            .@"return", .ret => ctx.* = .global,
        }
        printPrompt(io, conn, ctx.*);
        return;
    }

    reply(io, conn, "Unknown command!\n");
    printPrompt(io, conn, ctx.*);
}

fn handleSwitcher(
    io: std.Io,
    msg_buf: []u8,
    conn: std.Io.net.Stream,
    iter: *std.mem.TokenIterator(u8, .any),
    ctx: *Context,
    switcher: *lib.SwitcherState,
    endpoints: *lib.SafeEndpointList,
    current_id: *std.atomic.Value(usize),
) !void {
    const help_msg =
        \\Available Switcher Commands:
        \\  help (?)        - Show this message
        \\  status (info)   - Show switcher status and current server info
        \\  play            - Resume/start the switcher thread
        \\  pause           - Suspend the switcher thread
        \\  kill            - Completely stop the switcher thread
        \\  timer           - Set timer duration for siwtcher thread
        \\  endpoint        - Interactively manage endpoint
        \\  return (ret)    - Return to global session state
        \\  exit/quit (q)   - Close the admin connection
        \\
    ;
    const raw_cmd = iter.next() orelse {
        printPrompt(io, conn, ctx.*);
        return;
    };

    if (GlobalCmd.from(raw_cmd)) |cmd| {
        switch (cmd) {
            .exit, .quit, .q => return error.Exit,
            .help, .@"?" => reply(io, conn, help_msg),
            .list => try listEndpoints(io, conn, msg_buf, endpoints),
            .status, .info => try showStatus(
                io,
                conn,
                msg_buf,
                switcher,
                endpoints,
                current_id,
            ),
            .endpoint => ctx.* = .endpoint,
            .switcher => {}, // Ignore, already in switcher state
        }

        printPrompt(io, conn, ctx.*);
        return;
    }
    if (SwitcherCmd.from(raw_cmd)) |cmd| {
        switch (cmd) {
            .play => try handlePlay(io, conn, switcher),
            .pause => try handlePause(io, conn, switcher),
            .kill => try handleKill(io, conn, switcher),
            .timer => try handleTimer(io, conn, iter, msg_buf, switcher),
            .@"return", .ret => ctx.* = .global,
        }
        printPrompt(io, conn, ctx.*);
        return;
    }
    reply(io, conn, "Unknown command!\n");
    printPrompt(io, conn, ctx.*);
}
fn showStatus(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    switcher: *lib.SwitcherState,
    endpoints: *lib.SafeEndpointList,
    current_id: *std.atomic.Value(usize),
) !void {
    const id = current_id.load(.acquire);
    const running = switcher.is_running.load(.monotonic);
    const paused = switcher.is_paused; // Note: Accessing bool outside lock for status is usually fine

    const state_str = if (!running) "DEAD" else if (paused) "PAUSED" else "RUNNING";
    const timer = switcher.duration.load(.acquire);

    const endpoint = endpoints.getCopy(io, id) orelse {
        const msg = try std.fmt.bufPrint(
            msg_buf,
            "Switcher: {s} timer: {d}s\nEmpty endpoint list!\n",
            .{ state_str, timer },
        );
        reply(io, conn, msg);
        return;
    };

    const msg = try std.fmt.bufPrint(
        msg_buf,
        "Switcher: {s} timer: {d}s\nCurrent ID: {d} address: {f}\n",
        .{ state_str, timer, id, endpoint },
    );
    reply(io, conn, msg);
    return;
}

fn listEndpoints(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    endpoints: *lib.SafeEndpointList,
) !void {
    // Lock prior to doing anything
    endpoints.lockSharedUncancelable(io);
    // Unlock on finish
    defer endpoints.unlockShared(io);

    for (endpoints.getItems(), 0..) |endpoint, id| {
        const msg = try std.fmt.bufPrint(msg_buf, "ID: {d} address: {f}\n", .{ id, endpoint });
        reply(io, conn, msg);
    }
}

fn findID(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    iter: *std.mem.TokenIterator(u8, .any),
    endpoints: *lib.SafeEndpointList,
) !void {
    const full_addr = iter.next() orelse {
        reply(io, conn, "Error: Use 'find <ip:port>' format!\n");
        return;
    };

    // Split "1.2.3.4:5000" into "1.2.3.4" and "5000"
    var split_iter = std.mem.splitScalar(u8, full_addr, ':');
    const ip_part = split_iter.next() orelse {
        reply(io, conn, "Error: Wrong format (e.g., 1.2.3.4:5000)!\n");
        return;
    };
    const port_part = split_iter.next() orelse {
        reply(io, conn, "Error: Wrong format (e.g., 1.2.3.4:5000)!\n");
        return;
    };

    const port = std.fmt.parseInt(u16, port_part, 10) catch {
        reply(io, conn, "Error: Invalid port number\n");
        return;
    };

    const addr = std.Io.net.IpAddress.parse(ip_part, port) catch {
        reply(io, conn, "Error: Could not parse IP address\n");
        return;
    };

    // Lock prior to doing anything
    endpoints.lockSharedUncancelable(io);
    // Unlock on finish
    defer endpoints.unlockShared(io);

    for (endpoints.getItems(), 0..) |endpoint, id| {
        if (std.Io.net.IpAddress.eql(&endpoint, &addr)) {
            const msg = try std.fmt.bufPrint(msg_buf, "Found ID: {d} for address: {f}\n", .{ id, addr });
            reply(io, conn, msg);
            return;
        }
    }
    const msg = try std.fmt.bufPrint(msg_buf, "ID not found for address: {f}\n", .{addr});
    reply(io, conn, msg);
}

fn setEndpoint(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    iter: *std.mem.TokenIterator(u8, .any),
    endpoints: *lib.SafeEndpointList,
    current_id: *std.atomic.Value(usize),
) !void {
    const arg = iter.next() orelse {
        reply(io, conn, "Error: Missing ID\n");
        return;
    };

    const requested_id = std.fmt.parseInt(usize, arg, 10) catch {
        reply(io, conn, "Error: Invalid number\n");
        return;
    };

    // Lock prior to doing anything
    endpoints.lockSharedUncancelable(io);
    // Unlock on finish
    defer endpoints.unlockShared(io);

    if (requested_id >= endpoints.len(io)) {
        reply(io, conn, "Error: ID out of bounds\n");
        return;
    }

    const msg = try std.fmt.bufPrint(msg_buf, "Set active server to ID: {d}\n", .{requested_id});
    if (conn.socket.send(io, &conn.socket.address, msg)) {
        current_id.store(requested_id, .release);
        // Use unsafe here, out of bounds had been alerady checked
        const endpoint = endpoints.getCopyUnsafe(requested_id);
        std.log.info("Admin set endpoint: ID: {d} address: {f}", .{ requested_id, endpoint });
    } else |err| std.log.warn(
        "Ignoring setting endpoint. Admin reply failed: {s}",
        .{@errorName(err)},
    );
}

fn addEndpoint(
    io: std.Io,
    gpa: std.mem.Allocator,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    iter: *std.mem.TokenIterator(u8, .any),
    endpoints: *lib.SafeEndpointList,
) !void {
    var nothing_provided = true;

    // Split "1.2.3.4:5000" into "1.2.3.4" and "5000"
    while (iter.next()) |full_addr| {
        nothing_provided = false;
        var split_iter = std.mem.splitScalar(u8, full_addr, ':');
        const ip_part = split_iter.next() orelse {
            reply(io, conn, "Error: Wrong format (e.g., 1.2.3.4:5000)!\n");
            continue;
        };
        const port_part = split_iter.next() orelse {
            reply(io, conn, "Error: Wrong format (e.g., 1.2.3.4:5000)!\n");
            continue;
        };

        const port = std.fmt.parseInt(u16, port_part, 10) catch {
            const msg = try std.fmt.bufPrint(
                msg_buf,
                "Error: Invalid port number: {s}\n",
                .{port_part},
            );
            reply(io, conn, msg);
            continue;
        };

        const addr = std.Io.net.IpAddress.parse(ip_part, port) catch {
            const msg = try std.fmt.bufPrint(
                msg_buf,
                "Error: Could not parse IP address: {s}\n",
                .{full_addr},
            );
            reply(io, conn, msg);
            continue;
        };

        // Lock prior to doing anything
        endpoints.lockSharedUncancelable(io);
        // Unlock on finish
        defer endpoints.unlockShared(io);

        // Using current len and adding an item to array creates a valid ID
        const id = endpoints.len(io);

        const msg = try std.fmt.bufPrint(msg_buf, "Added ID: {d} address: {f}\n", .{ id, addr });
        if (conn.socket.send(io, &conn.socket.address, msg)) {
            try endpoints.addUnsafe(gpa, addr);
            std.log.info("Admin added ID: {d} address: {f}", .{ id, addr });
        } else |err| std.log.warn(
            "Ignoring adding endpoint. Admin reply failed: {s}",
            .{@errorName(err)},
        );
    }
    if (nothing_provided) reply(io, conn, "Use 'add <ip:port>' format!");
}

fn removeEndpoint(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    iter: *std.mem.TokenIterator(u8, .any),
    endpoints: *lib.SafeEndpointList,
    current_id: *std.atomic.Value(usize),
) !void {
    const arg = iter.next() orelse {
        reply(io, conn, "Error: Missing ID\n");
        return;
    };

    const id = std.fmt.parseInt(usize, arg, 10) catch {
        reply(io, conn, "Error: Invalid ID\n");
        return;
    };

    // Lock prior to doing anything
    endpoints.lockSharedUncancelable(io);
    // Unlock on finish
    defer endpoints.unlockShared(io);

    // Already locked, use tiems.len directly
    const list_len = endpoints.list.items.len;
    if (id >= list_len) {
        reply(io, conn, "Error: ID out of bounds\n");
        return;
    }

    const addrs = endpoints.getItems();
    const addr = addrs[id];
    const msg = try std.fmt.bufPrint(msg_buf, "Removed ID: {d} address: {f}\n", .{ id, addr });

    if (conn.socket.send(io, &conn.socket.address, msg)) {
        if (id == list_len - 1) {
            _ = endpoints.popUnsafe();
        } else {
            _ = endpoints.orderedRemoveUnsafe(id);
            // CRITICAL: If removed an ID lower than our current_id,
            // decrement current_id to keep pointing at the same server.
            var current = current_id.load(.acquire);
            while (true) {
                var new = current;
                if (id < current) {
                    new = current - 1;
                } else if (id == current) {
                    new = if (id > 0) id - 1 else 0;
                } else {
                    // If id > current, current_id doesn't need to change
                    break;
                }

                // Attempt to update. If current changed in another thread,
                // cmpxchgWeak updates 'current' and returns an error, looping again.
                current = current_id.cmpxchgWeak(current, new, .release, .acquire) orelse break;
            }
        }
        std.log.info("Admin removed ID: {d} address: {f}", .{ id, addr });
    } else |err| std.log.warn(
        "Ignoring removing endpoint. Admin reply failed: {s}",
        .{@errorName(err)},
    );
}

fn handlePlay(io: std.Io, conn: std.Io.net.Stream, switcher: *lib.SwitcherState) !void {
    if (switcher.is_running.load(.acquire)) {
        switcher.play();
        reply(io, conn, "Switcher thread resumed.\n");
    } else {
        try switcher.start();
        reply(io, conn, "Switcher thread started.\n");
    }
}

fn handlePause(io: std.Io, conn: std.Io.net.Stream, switcher: *lib.SwitcherState) !void {
    switcher.pause();
    reply(io, conn, "Switcher thread paused.\n");
}

fn handleKill(io: std.Io, conn: std.Io.net.Stream, switcher: *lib.SwitcherState) !void {
    switcher.stop();
    reply(io, conn, "Switcher thread terminated.\n");
}

fn handleTimer(
    io: std.Io,
    conn: std.Io.net.Stream,
    iter: *std.mem.TokenIterator(u8, .any),
    msg_buf: []u8,
    switcher: *lib.SwitcherState,
) !void {
    const arg = iter.next() orelse {
        reply(io, conn, "Error: Missing seconds!\n");
        return;
    };

    const new_seconds = std.fmt.parseInt(isize, arg, 10) catch {
        reply(io, conn, "Error: Invalid number!\n");
        return;
    };

    if (new_seconds < 0) {
        reply(io, conn, "Error: Duration cannot be negative!\n");
        return;
    }

    const msg = try std.fmt.bufPrint(msg_buf, "Switcher timer set to {d}s.\n", .{new_seconds});
    if (conn.socket.send(io, &conn.socket.address, msg)) {
        switcher.duration.store(new_seconds, .release);
        std.log.info("Admin set timer duration: {d}s", .{new_seconds});
    } else |err| std.log.warn(
        "Ignoring setting timer duration. Admin reply failed: {s}",
        .{@errorName(err)},
    );
}
