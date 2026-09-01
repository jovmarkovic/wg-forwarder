const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parser.zig");
const timestamp = @import("timestamp.zig");
const EndpointPool = @import("endpoints.zig").EndpointPool;
const SwitcherState = @import("switcher.zig").SwitcherState;

/// public API
pub fn adminServer(
    io: std.Io,
    gpa: std.mem.Allocator,
    ip: []const u8,
    port: u16,
    endpoints: *EndpointPool,
    switcher: *SwitcherState,
) !void {
    const addr = try std.Io.net.IpAddress.parse(ip, port);
    _ = try EndpointPool.requireFamily(addr, endpoints.addr_family);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{
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

        var buf: [2048]u8 = undefined;
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
                    switcher,
                ) catch |err| switch (err) {
                    error.Exit => {
                        // Convert error.Exit to graceful shutdown of the session
                        conn.socket.send(io, &conn.socket.address, "Bye!\n") catch {};
                        break;
                    },
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

// command vocabulary

const Context = enum {
    global,
    endpoint,
    switcher,
};

const GlobalCmd = enum {
    const Self = @This();
    help,
    @"?",
    status,
    list,
    info,
    switcher,
    endpoint,
    exit,
    quit,
    q,

    /// Helper to turn the string into this enum
    fn from(s: []const u8) ?Self {
        return std.meta.stringToEnum(Self, s);
    }
};

const EndpointCmd = enum {
    const Self = @This();
    add,
    find,
    edit,
    set,
    rm,
    @"return",
    ret,

    /// Helper to turn the string into this enum
    fn from(s: []const u8) ?Self {
        return std.meta.stringToEnum(Self, s);
    }
};

const SwitcherCmd = enum {
    const Self = @This();
    play,
    pause,
    stop,
    timer,
    @"return",
    ret,

    /// Helper to turn the string into this enum
    fn from(s: []const u8) ?Self {
        return std.meta.stringToEnum(Self, s);
    }
};

// session plumbing

/// Process admin_console input
fn processInput(
    io: std.Io,
    gpa: std.mem.Allocator,
    conn: std.Io.net.Stream,
    data: []u8,
    ctx: *Context,
    endpoints: *EndpointPool,
    switcher: *SwitcherState,
) error{Exit}!void {
    var msg_buf: [2048]u8 = undefined;
    // Comptime-known here (an array's length is part of its type), so a buffer
    // too small for the longest listing line is a build failure, not a log line.
    EndpointPool.checkReplyBuf(msg_buf.len);

    var iter = std.mem.tokenizeAny(u8, data, " \r\n\t");

    // Each handler only returns error.Exit
    switch (ctx.*) {
        .global => try handleGlobal(
            io,
            conn,
            &msg_buf,
            &iter,
            ctx,
            switcher,
            endpoints,
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
        ),
        .switcher => try handleSwitcher(
            io,
            &msg_buf,
            conn,
            &iter,
            ctx,
            switcher,
            endpoints,
        ),
    }
}

/// Helper for catching errors on reply
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

// Start of context dispatch

/// Global state
fn handleGlobal(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    iter: *std.mem.TokenIterator(u8, .any),
    ctx: *Context,
    switcher: *SwitcherState,
    endpoints: *EndpointPool,
) !void {
    const help_msg =
        \\Available Global Commands:
        \\  help (?)        - Show this message
        \\  status (info)   - Show switcher status and current server info
        \\  list            - List all available endpoints
        \\  switcher        - Interactively manage switcher
        \\  endpoint        - Interactively manage endpoint
        \\  exit/quit (q)   - Close the admin connection
        \\
    ;
    const raw_cmd = iter.next() orelse {
        printPrompt(io, conn, ctx.*);
        return;
    };

    const cmd = GlobalCmd.from(raw_cmd) orelse {
        reply(io, conn, "Unknown command!\n");
        printPrompt(io, conn, ctx.*);
        return;
    };

    switch (cmd) {
        .exit, .quit, .q => return error.Exit,
        .help, .@"?" => reply(io, conn, help_msg),
        .status, .info => showStatus(
            io,
            conn,
            msg_buf,
            switcher,
            endpoints,
        ),
        .list => listEndpoints(io, conn, msg_buf, endpoints),
        .switcher => ctx.* = .switcher,
        .endpoint => ctx.* = .endpoint,
    }
    // After every successful command:
    printPrompt(io, conn, ctx.*);
}

/// Endpoint state
fn handleEndpoint(
    io: std.Io,
    gpa: std.mem.Allocator,
    msg_buf: []u8,
    conn: std.Io.net.Stream,
    iter: *std.mem.TokenIterator(u8, .any),
    ctx: *Context,
    switcher: *SwitcherState,
    endpoints: *EndpointPool,
) !void {
    const help_msg =
        \\Available Endpoint Commands:
        \\  help (?)           - Show this message
        \\  list               - List all available endpoints
        \\  add ip:port        - Adds one or more endpoints
        \\                         Use 'ip:port ip:port' with out qotes to add multiple
        \\  find ip:port       - Find endpoint status from the address 
        \\  edit <n> <ip:port> - Edit an endpoint address, slot optional to pass
        \\  set <n> <ip:port>  - Manually set the active endpoint by address, slot optional to pass
        \\  rm <n> <ip:port>   - Remove endpoint by address, slot optional to pass
        \\  status (info)      - Show switcher status and current server info
        \\  switcher           - Interactively manage switcher 
        \\  return (ret)       - Return to global session state
        \\  exit/quit (q)      - Close the admin connection
        \\
    ;

    const raw_cmd = iter.next() orelse {
        printPrompt(io, conn, ctx.*);
        return;
    };

    // Process global commands first
    if (GlobalCmd.from(raw_cmd)) |cmd| {
        switch (cmd) {
            .exit, .quit, .q => return error.Exit,
            .help, .@"?" => reply(io, conn, help_msg),
            .list => listEndpoints(io, conn, msg_buf, endpoints),
            .status, .info => showStatus(
                io,
                conn,
                msg_buf,
                switcher,
                endpoints,
            ),
            .switcher => ctx.* = .switcher,
            .endpoint => {}, // Ignore, already in endpoint state
        }

        printPrompt(io, conn, ctx.*);
        return;
    }

    if (EndpointCmd.from(raw_cmd)) |cmd| {
        switch (cmd) {
            .add => endpointAdd(
                io,
                gpa,
                conn,
                msg_buf,
                iter,
                endpoints,
            ),
            .find => endpointFindAddr(
                io,
                conn,
                msg_buf,
                iter,
                endpoints,
            ),
            .edit => endpointEdit(
                io,
                conn,
                msg_buf,
                iter,
                endpoints,
            ),
            .set => endpointSet(
                io,
                conn,
                msg_buf,
                iter,
                endpoints,
            ),
            .rm => endpointRemove(
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

/// Switcher state
fn handleSwitcher(
    io: std.Io,
    msg_buf: []u8,
    conn: std.Io.net.Stream,
    iter: *std.mem.TokenIterator(u8, .any),
    ctx: *Context,
    switcher: *SwitcherState,
    endpoints: *EndpointPool,
) !void {
    const help_msg =
        \\Available Switcher Commands:
        \\  help (?)        - Show this message
        \\  status (info)   - Show switcher status and current server info
        \\  play            - Resume/start the switcher thread
        \\  pause           - Suspend the switcher thread
        \\  stop            - Fully stop the switcher thread
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

    // Process global commands first
    if (GlobalCmd.from(raw_cmd)) |cmd| {
        switch (cmd) {
            .exit, .quit, .q => return error.Exit,
            .help, .@"?" => reply(io, conn, help_msg),
            .list => listEndpoints(io, conn, msg_buf, endpoints),
            .status, .info => showStatus(
                io,
                conn,
                msg_buf,
                switcher,
                endpoints,
            ),
            .endpoint => ctx.* = .endpoint,
            .switcher => {}, // Ignore, already in switcher state
        }

        printPrompt(io, conn, ctx.*);
        return;
    }
    if (SwitcherCmd.from(raw_cmd)) |cmd| {
        switch (cmd) {
            .play => switcherPlay(io, conn, msg_buf, switcher),
            .pause => switcherPause(io, conn, switcher),
            .stop => switcherStop(io, conn, switcher),
            .timer => switcherTime(io, conn, iter, msg_buf, switcher),
            .@"return", .ret => ctx.* = .global,
        }
        printPrompt(io, conn, ctx.*);
        return;
    }
    reply(io, conn, "Unknown command!\n");
    printPrompt(io, conn, ctx.*);
}

// Global Commands

/// Status (info)
fn showStatus(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    switcher: *SwitcherState,
    endpoints: *EndpointPool,
) void {
    const st = switcher.status();
    const state_str = if (!st.running) "DEAD" else if (st.paused) "PAUSED" else "RUNNING";
    const timer = st.idle_timeout orelse 0;

    const entry = endpoints.currentEntry(io);

    const msg = if (entry) |e|
        std.fmt.bufPrint(
            msg_buf,
            "Switcher: {s} timer: {d}s\nCurrent slot: {d} address: {f} health: {s}\n",
            .{ state_str, timer, e.index, e.endpoint.addr, @tagName(e.endpoint.health) },
        ) catch "Status line too long for the reply buffer.\n"
    else
        std.fmt.bufPrint(
            msg_buf,
            "Switcher: {s} timer: {d}s\nNo current endpoint.\n",
            .{ state_str, timer },
        ) catch "Status line too long for the reply buffer.\n";

    reply(io, conn, msg);
    return;
}

/// List
fn listEndpoints(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    endpoints: *EndpointPool,
) void {
    var start: ?u32 = 0;
    var found = false;
    while (start) |s| {
        var w = std.Io.Writer.fixed(msg_buf);
        start = endpoints.writePage(io, &w, s);
        if (w.end > 0) {
            found = true;
            reply(io, conn, w.buffer[0..w.end]); // one send per page, outside the lock
        }
    }
    if (!found) reply(io, conn, "Empty endpoint pool.\n");
}

// Start of endpoint commands

/// Add
fn endpointAdd(
    io: std.Io,
    gpa: std.mem.Allocator,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    iter: *std.mem.TokenIterator(u8, .any),
    endpoints: *EndpointPool,
) void {
    var nothing_provided = true;

    while (iter.next()) |full_addr| {
        nothing_provided = false;
        const addr = parseAddrOrReply(
            io,
            conn,
            msg_buf,
            full_addr,
        ) orelse continue;

        // Using current len and adding an item to array creates a valid ID
        const id = endpoints.add(io, gpa, addr) catch |err| {
            const msg = std.fmt.bufPrint(msg_buf, "Error adding: {s} {s}", .{
                full_addr,
                addErrorText(err),
            }) catch addErrorTextComptime(err);
            reply(io, conn, msg);
            continue;
        };

        const msg = std.fmt.bufPrint(msg_buf, "Added slot: {d} address: {f}.\n", .{
            id,
            addr,
        }) catch "Added endpoint.\n";
        reply(io, conn, msg);
    }
    if (nothing_provided) reply(io, conn, "Use 'add <ip:port>' or 'add [<ipv6>]:<port>' — multiple allowed\n");
}

/// Find
fn endpointFindAddr(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    iter: *std.mem.TokenIterator(u8, .any),
    endpoints: *EndpointPool,
) void {
    const full_addr = iter.next() orelse {
        reply(io, conn, "Use 'find <ip:port>' or 'find [<ipv6>]:<port>.'\n");
        return;
    };

    const addr = parseAddrOrReply(
        io,
        conn,
        msg_buf,
        full_addr,
    ) orelse return;

    var found = false;
    var start: ?u32 = 0;
    while (start) |s| {
        var w = std.Io.Writer.fixed(msg_buf);
        start = endpoints.findByAddr(io, &w, addr, s);
        if (w.end > 0) {
            found = true;
            reply(io, conn, w.buffer[0..w.end]);
        }
    }

    if (!found) {
        const msg = std.fmt.bufPrint(msg_buf, "Endpoint not found: {f}\n", .{
            addr,
        }) catch "Endpoint not found.\n";
        reply(io, conn, msg);
    }
}

/// Edit
fn endpointEdit(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    iter: *std.mem.TokenIterator(u8, .any),
    endpoints: *EndpointPool,
) void {
    const usage = "Use 'edit <old> <new>' or 'edit <slot> <old> <new>'.\n";

    const target = parseTargetOrReply(
        2,
        io,
        conn,
        msg_buf,
        iter,
        usage,
    ) orelse return;

    const old = endpoints.edit(
        io,
        target.hint,
        target.addrs[0],
        target.addrs[1],
    ) catch |err| {
        const msg = std.fmt.bufPrint(
            msg_buf,
            "Error editing {f}: {s}",
            .{ target.addrs[0], editErrorText(err) },
        ) catch editErrorTextComptime(err);
        reply(io, conn, msg);
        return;
    };
    const msg = std.fmt.bufPrint(msg_buf, "Changed {f} to {f} (was health: {s}).\n", .{
        target.addrs[0], target.addrs[1], @tagName(old.health),
    }) catch "Endpoint changed.\n";
    reply(io, conn, msg);
    std.log.info("Admin edited endpoint:\n  old:{f}\n  new:{f}", .{ target.addrs[0], target.addrs[1] });
}

/// Set
fn endpointSet(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    iter: *std.mem.TokenIterator(u8, .any),
    endpoints: *EndpointPool,
) void {
    const usage = "Use 'set <ip:port>' or 'set <slot> <ip:port>'.\n";

    const target = parseTargetOrReply(
        1,
        io,
        conn,
        msg_buf,
        iter,
        usage,
    ) orelse return;

    const endpoint = endpoints.setCurrent(io, target.hint, target.addrs[0]);

    if (endpoint) {
        const msg = std.fmt.bufPrint(msg_buf, "Active endpoint: {f}.\n", .{
            target.addrs[0],
        }) catch "Active endpoint set.\n";
        reply(io, conn, msg);
        std.log.info("Admin set endpoint: {f}", .{target.addrs[0]});
    } else {
        const err = std.fmt.bufPrint(
            msg_buf,
            "Error: no endpoint: {f}.'\n",
            .{target.addrs[0]},
        ) catch "Error: no such endpoint.\n";
        reply(io, conn, err);
        return;
    }
}

/// Remove (rm)
fn endpointRemove(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    iter: *std.mem.TokenIterator(u8, .any),
    endpoints: *EndpointPool,
) void {
    const usage = "Use 'rm <ip:port>' or 'rm <slot> <ip:port>'.\n";
    const target = parseTargetOrReply(
        1,
        io,
        conn,
        msg_buf,
        iter,
        usage,
    ) orelse return;

    if (endpoints.removeByAddr(io, target.hint, target.addrs[0])) |ep| {
        const msg = std.fmt.bufPrint(
            msg_buf,
            "Removed endpoint: {f}.\n",
            .{ep.addr},
        ) catch "Removed endpoint.\n";
        reply(io, conn, msg);
        std.log.info("Admin removed endpoint: {f}", .{ep.addr});
    } else {
        const msg = std.fmt.bufPrint(
            msg_buf,
            "Endpoint: {f} not found.\n",
            .{target.addrs[0]},
        ) catch "Endpoint not found.\n";
        reply(io, conn, msg);
    }
}

// switcher commands

/// Play
fn switcherPlay(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    switcher: *SwitcherState,
) void {
    const outcome = switcher.startOrPlay() catch |err| {
        const msg: []const u8 = switch (err) {
            error.NoTimerConfigured => "Error: no timer configured. Use 'timer <seconds>' first.\n",
            else => blk: {
                // Log only system error
                std.log.err("switcher start failed: {s}.", .{@errorName(err)});
                break :blk
                // Send more complete error message in a reply if buffer allows it
                std.fmt.bufPrint(
                    msg_buf,
                    "Error: could not start switcher: {s}.\n",
                    .{@errorName(err)},
                ) catch "Error: could not start switcher.\n";
            },
        };
        reply(io, conn, msg);
        return;
    };

    reply(io, conn, switch (outcome) {
        .started => "Switcher thread started.\n",
        .resumed => "Switcher thread resumed.\n",
        .already_running => "Switcher is already running.\n",
    });
}

/// Pause
fn switcherPause(io: std.Io, conn: std.Io.net.Stream, switcher: *SwitcherState) void {
    switcher.pause();
    reply(io, conn, "Switcher thread paused.\n");
}

/// Stop
fn switcherStop(io: std.Io, conn: std.Io.net.Stream, switcher: *SwitcherState) void {
    switcher.stop();
    reply(io, conn, "Switcher thread terminated.\n");
}

/// Time
fn switcherTime(
    io: std.Io,
    conn: std.Io.net.Stream,
    iter: *std.mem.TokenIterator(u8, .any),
    msg_buf: []u8,
    switcher: *SwitcherState,
) void {
    const arg = iter.next() orelse {
        reply(io, conn, "Error: Missing seconds.\n");
        return;
    };

    const new_seconds = std.fmt.parseInt(i64, arg, 10) catch {
        reply(io, conn, "Error: Invalid number.\n");
        return;
    };

    if (new_seconds <= 0) {
        reply(io, conn, "Error: Duration cannot be negative or zero.\n");
        return;
    }

    const msg = std.fmt.bufPrint(
        msg_buf,
        "Switcher timer set to {d}s.\n",
        .{new_seconds},
    ) catch "Switcher timer set.\n";
    reply(io, conn, msg);
    switcher.setDuration(new_seconds);
    std.log.info("Admin set timer duration: {d}s", .{new_seconds});
}

// argument parsing

/// Holds a potential slot number or an Endpoint address
fn Targets(comptime n: u2) type {
    return struct { hint: ?u32, addrs: [n]std.Io.net.IpAddress };
}

/// Parse the argument form shared `set` and `remove (rm)`.
/// Replies to the operator itself on any problem and returns null.
fn parseTargetOrReply(
    comptime n: u2,
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    iter: *std.mem.TokenIterator(u8, .any),
    usage: []const u8,
) ?Targets(n) {
    comptime std.debug.assert(n == 1 or n == 2);

    var out: Targets(n) = .{ .hint = null, .addrs = undefined };

    // Save the starting point after uisng a command if hint fails parsing.
    // Calling reset() is wrong here, command arg is correctly processed at this point.
    const init = iter.index;
    const first = iter.next() orelse {
        reply(io, conn, usage);
        return null;
    };

    // Use for formatting potential parsing error
    out.hint = std.fmt.parseInt(u32, first, 10) catch blk: {
        // Rewind starting point for address parsing
        iter.index = init;
        break :blk null;
    };

    for (&out.addrs) |*addr| {
        const arg = iter.next() orelse {
            reply(io, conn, usage);
            return null;
        };
        addr.* = parseAddrOrReply(io, conn, msg_buf, arg) orelse return null;
    }

    // If hint is null and more args are passed than addresses needed,
    // first argument must be a slot number and reply an error for index parsing
    if (out.hint == null and iter.peek() != null) {
        const msg = std.fmt.bufPrint(
            msg_buf,
            "Error: '{s}' is not a valid slot number.\n",
            .{first},
        ) catch "Error: first argument is not a valid slot number.\n";

        reply(io, conn, msg);
        return null;
    }

    return out; // anything past the last address is left unread and discarded
}

/// Helper for parsing address and reply on error.
fn parseAddrOrReply(
    io: std.Io,
    conn: std.Io.net.Stream,
    msg_buf: []u8,
    text: []const u8,
) ?std.Io.net.IpAddress {
    return parser.parseHostPort(text) catch |err| {
        const msg = std.fmt.bufPrint(msg_buf, "Error: {s} {s}", .{
            text, hostPortErrorText(err),
        }) catch HostPortErrorTextCmptime(err);
        reply(io, conn, msg);
        return null;
    };
}

// Error texts

fn hostPortErrorText(err: parser.AddrParseError) []const u8 {
    return switch (err) {
        error.MissingPort => "missing port. (e.g. 1.2.3.4:5000).\n",
        error.BracketsRequired => "IPv6 needs brackets. (e.g. [::1]:5000).\n",
        error.UnterminatedBracket => "unterminated '[' in address.\n",
        error.InvalidPort => "invalid port number.\n",
        error.InvalidAddress => "could not parse IP address.\n",
    };
}

fn HostPortErrorTextCmptime(err: parser.AddrParseError) []const u8 {
    const p = "Error: ";
    return switch (err) {
        error.MissingPort => p ++ "missing port. (e.g. 1.2.3.4:5000).\n",
        error.BracketsRequired => p ++ "IPv6 needs brackets. (e.g. [::1]:5000).\n",
        error.UnterminatedBracket => p ++ "unterminated '[' in address.\n",
        error.InvalidPort => p ++ "invalid port number.\n",
        error.InvalidAddress => p ++ "could not parse IP address.\n",
    };
}
fn addErrorText(err: error{ Duplicate, WrongFamily, OutOfMemory }) []const u8 {
    return switch (err) {
        error.Duplicate => "address already in the pool.\n",
        error.WrongFamily => "wrong address family.\n",
        error.OutOfMemory => "out of memory.\n",
    };
}

fn addErrorTextComptime(err: error{ Duplicate, WrongFamily, OutOfMemory }) []const u8 {
    const p = "Error: ";
    return switch (err) {
        error.Duplicate => p ++ "address already in the pool.\n",
        error.WrongFamily => p ++ "wrong address family.\n",
        error.OutOfMemory => p ++ "out of memory.\n",
    };
}

fn editErrorText(err: error{ NotFound, Duplicate, WrongFamily }) []const u8 {
    return switch (err) {
        error.NotFound => "old address is not in the pool.\n",
        error.Duplicate => "address already in the pool.\n",
        error.WrongFamily => "wrong address family.\n",
    };
}
fn editErrorTextComptime(err: error{ NotFound, Duplicate, WrongFamily }) []const u8 {
    const p = "Error: ";
    return switch (err) {
        error.NotFound => p ++ "old address is not in the pool.\n",
        error.Duplicate => p ++ "address already in the pool.\n",
        error.WrongFamily => p ++ "wrong address family.\n",
    };
}

// Tests

const testing = std.testing;

// command vocabulary

test "GlobalCmd: every documented spelling parses" {
    const rows = [_]struct { s: []const u8, want: GlobalCmd }{
        .{ .s = "help", .want = .help },
        .{ .s = "?", .want = .@"?" },
        .{ .s = "list", .want = .list },
        .{ .s = "status", .want = .status },
        .{ .s = "info", .want = .info },
        .{ .s = "switcher", .want = .switcher },
        .{ .s = "endpoint", .want = .endpoint },
        .{ .s = "exit", .want = .exit },
        .{ .s = "quit", .want = .quit },
        .{ .s = "q", .want = .q },
    };
    for (rows) |r| try testing.expectEqual(r.want, GlobalCmd.from(r.s).?);

    // Every field is reachable by its own name
    for (std.meta.fieldNames(GlobalCmd)) |name| {
        try testing.expect(GlobalCmd.from(name) != null);
    }
}

test "EndpointCmd: every documented spelling parses" {
    const rows = [_]struct { s: []const u8, want: EndpointCmd }{
        .{ .s = "add", .want = .add },
        .{ .s = "find", .want = .find },
        .{ .s = "edit", .want = .edit },
        .{ .s = "set", .want = .set },
        .{ .s = "rm", .want = .rm },
        .{ .s = "return", .want = .@"return" },
        .{ .s = "ret", .want = .ret },
    };
    for (rows) |r| try testing.expectEqual(r.want, EndpointCmd.from(r.s).?);

    for (std.meta.fieldNames(EndpointCmd)) |name| {
        try testing.expect(EndpointCmd.from(name) != null);
    }
}

test "SwitcherCmd: every documented spelling parses" {
    const rows = [_]struct { s: []const u8, want: SwitcherCmd }{
        .{ .s = "play", .want = .play },
        .{ .s = "pause", .want = .pause },
        .{ .s = "stop", .want = .stop },
        .{ .s = "timer", .want = .timer },
        .{ .s = "return", .want = .@"return" },
        .{ .s = "ret", .want = .ret },
    };
    for (rows) |r| try testing.expectEqual(r.want, SwitcherCmd.from(r.s).?);

    for (std.meta.fieldNames(SwitcherCmd)) |name| {
        try testing.expect(SwitcherCmd.from(name) != null);
    }
}

test "command parsing rejects near-misses" {
    for ([_][]const u8{ "", " ", "HELP", "Help", "hel", "helpp", "l", "lis", "exit;", "q " }) |s| {
        try testing.expect(GlobalCmd.from(s) == null);
    }
    for ([_][]const u8{ "a", "ad", "adds", "REMOVE", "se", "sett", "found" }) |s| {
        try testing.expect(EndpointCmd.from(s) == null);
    }
    for ([_][]const u8{ "kill", "PLAY", "pla", "stopp", "time", "timers" }) |s| {
        try testing.expect(SwitcherCmd.from(s) == null);
    }
}

test "GlobalCmd: no overlap between other two vocabularies" {
    for (std.meta.fieldNames(GlobalCmd)) |name| {
        try testing.expect(EndpointCmd.from(name) == null);
        try testing.expect(SwitcherCmd.from(name) == null);
    }
    for (std.meta.fieldNames(EndpointCmd)) |name| {
        try testing.expect(GlobalCmd.from(name) == null);
    }
    for (std.meta.fieldNames(SwitcherCmd)) |name| {
        try testing.expect(GlobalCmd.from(name) == null);
    }
}

// operator-facing error text

/// Every one of these lands directly in a reply,each must terminate its own line.
fn expectReplyLine(text: []const u8) !void {
    try testing.expect(text.len > 0);
    try testing.expectEqual(@as(u8, '\n'), text[text.len - 1]);
}

/// An operator who cannot tell two failures apart will debug the wrong one.
fn expectAllDistinct(texts: []const []const u8) !void {
    for (texts, 0..) |a, i| {
        for (texts[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
    }
}

const err_prefix = "Error: ";

const AddError = error{ Duplicate, WrongFamily, OutOfMemory };
const EditError = error{ NotFound, Duplicate, WrongFamily };

const addr_errs = [_]parser.AddrParseError{
    error.MissingPort,
    error.BracketsRequired,
    error.UnterminatedBracket,
    error.InvalidPort,
    error.InvalidAddress,
};
const add_errs = [_]AddError{ error.Duplicate, error.WrongFamily, error.OutOfMemory };
const edit_errs = [_]EditError{ error.NotFound, error.Duplicate, error.WrongFamily };

test "error text: every message terminates its own line" {
    for (addr_errs) |e| {
        try expectReplyLine(hostPortErrorText(e));
        try expectReplyLine(HostPortErrorTextCmptime(e));
    }
    for (add_errs) |e| {
        try expectReplyLine(addErrorText(e));
        try expectReplyLine(addErrorTextComptime(e));
    }
    for (edit_errs) |e| {
        try expectReplyLine(editErrorText(e));
        try expectReplyLine(editErrorTextComptime(e));
    }
}

test "error text: the prefix belongs to the comptime variant alone" {
    for (addr_errs) |e| {
        try testing.expect(!std.mem.startsWith(u8, hostPortErrorText(e), err_prefix));
        try testing.expect(std.mem.startsWith(u8, HostPortErrorTextCmptime(e), err_prefix));
    }
    for (add_errs) |e| {
        try testing.expect(!std.mem.startsWith(u8, addErrorText(e), err_prefix));
        try testing.expect(std.mem.startsWith(u8, addErrorTextComptime(e), err_prefix));
    }
    for (edit_errs) |e| {
        try testing.expect(!std.mem.startsWith(u8, editErrorText(e), err_prefix));
        try testing.expect(std.mem.startsWith(u8, editErrorTextComptime(e), err_prefix));
    }
}

test "error text: a fallback still names the problem" {
    for (addr_errs) |e| try testing.expect(HostPortErrorTextCmptime(e).len > err_prefix.len + 8);
    for (add_errs) |e| try testing.expect(addErrorTextComptime(e).len > err_prefix.len + 8);
    for (edit_errs) |e| try testing.expect(editErrorTextComptime(e).len > err_prefix.len + 8);
}

test "error text: distinct errors within a set read differently" {
    var addr_texts: [addr_errs.len][]const u8 = undefined;
    for (addr_errs, &addr_texts) |e, *slot| slot.* = hostPortErrorText(e);
    try expectAllDistinct(&addr_texts);

    var add_texts: [add_errs.len][]const u8 = undefined;
    for (add_errs, &add_texts) |e, *slot| slot.* = addErrorText(e);
    try expectAllDistinct(&add_texts);

    var edit_texts: [edit_errs.len][]const u8 = undefined;
    for (edit_errs, &edit_texts) |e, *slot| slot.* = editErrorText(e);
    try expectAllDistinct(&edit_texts);
}

test "error text: each comptime fallback is its runtime text plus the prefix" {
    for (addr_errs) |e| {
        const fallback = HostPortErrorTextCmptime(e);
        try testing.expectEqualStrings(hostPortErrorText(e), fallback[err_prefix.len..]);
    }
    for (add_errs) |e| {
        const fallback = addErrorTextComptime(e);
        try testing.expectEqualStrings(addErrorText(e), fallback[err_prefix.len..]);
    }
    for (edit_errs) |e| {
        const fallback = editErrorTextComptime(e);
        try testing.expectEqualStrings(editErrorText(e), fallback[err_prefix.len..]);
    }
}

// argument parsing

/// A real loopback datagram pair. The parse helpers reply to the operator
/// themselves rather than returning an error, so testing them means reading
/// what actually went out on the wire. `reply` sends to `conn.socket.address`,
/// so pointing that at `client` is the whole trick.
const TestConn = struct {
    conn: std.Io.net.Stream,

    /// Written *after* the code under test, so a blocking receive always has
    /// something to return. Getting this back means nothing was replied — no
    /// timeout machinery and no non-blocking read needed.
    const silence = "<no reply>";

    /// One datagram socket addressed to itself. `reply` sends to
    /// `conn.socket.address`, and for a self-addressed socket that field means
    /// exactly what std documents it to mean — the socket's own address — so
    /// nothing here is repurposed. The kernel loops each datagram straight back
    /// into this socket's own receive queue.
    fn init() !TestConn {
        const any = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        const sock = try std.Io.net.IpAddress.bind(&any, testing.io, .{ .mode = .dgram });
        return .{ .conn = .{ .socket = sock } };
    }

    fn deinit(t: *TestConn) void {
        t.conn.socket.close(testing.io);
    }

    /// The first datagram the code under test sent, or `silence`.
    ///
    /// Datagrams queue; They stay when a later one is read.
    /// When a real reply comes back, the sentinel is still sitting behind it.
    /// It needs to be drained to make the next call on this connection return it
    /// instead of that call's reply. Reading it back is the only way to remove
    /// the sentinel since there is no syscall to flush a receive queue.
    fn firstReply(t: *TestConn, buf: []u8) ![]const u8 {
        try t.conn.socket.send(testing.io, &t.conn.socket.address, silence);

        const first = (try t.conn.socket.receive(testing.io, buf)).data;
        if (std.mem.eql(u8, first, silence)) return first; // nothing was replied

        // Drain up to and including our own sentinel. Anything else in between
        // is a second or third reply, which this helper does not report on.
        // The separate buffer keeps the returned slice into `buf` valid.
        var drain: [512]u8 = undefined;
        while (!std.mem.eql(u8, (try t.conn.socket.receive(testing.io, &drain)).data, silence)) {}
        return first;
    }
};

/// Mimic processInput() tokenization
fn argsOf(line: []const u8) std.mem.TokenIterator(u8, .any) {
    var iter = std.mem.tokenizeAny(u8, line, " \r\n\t");
    _ = iter.next();
    return iter;
}

const usage_1 = "Use 'set <ip:port>' or 'set <slot> <ip:port>'.\n";
const usage_2 = "Use 'edit <old> <new>' or 'edit <slot> <old> <new>'.\n";

// parseAddrOrReply

test "parseAddrOrReply: a valid address is returned unchanged and nothing is sent" {
    var t = try TestConn.init();
    defer t.deinit();
    var msg_buf: [256]u8 = undefined;
    var rbuf: [256]u8 = undefined;

    const got = parseAddrOrReply(testing.io, t.conn, &msg_buf, "127.0.0.1:1000") orelse
        return error.TestExpectedAddress;

    try testing.expectEqual(@as(u16, 1000), got.ip4.port);
    try testing.expectEqualStrings(TestConn.silence, try t.firstReply(&rbuf));
}

test "parseAddrOrReply: an ipv6 literal keeps its family" {
    var t = try TestConn.init();
    defer t.deinit();
    var msg_buf: [256]u8 = undefined;
    var rbuf: [256]u8 = undefined;

    const got = parseAddrOrReply(testing.io, t.conn, &msg_buf, "[::1]:1000") orelse
        return error.TestExpectedAddress;

    try testing.expectEqual(@as(u16, 1000), got.ip6.port);
    try testing.expectEqualStrings(TestConn.silence, try t.firstReply(&rbuf));
}

test "parseAddrOrReply: a bad address returns null and echoes the token" {
    var t = try TestConn.init();
    defer t.deinit();
    var msg_buf: [256]u8 = undefined;
    var rbuf: [256]u8 = undefined;

    try testing.expect(parseAddrOrReply(testing.io, t.conn, &msg_buf, "nonsense") == null);

    const sent = try t.firstReply(&rbuf);
    try testing.expect(std.mem.find(u8, sent, "nonsense") != null);
    try testing.expect(std.mem.endsWith(u8, sent, hostPortErrorText(error.MissingPort)));
}

// parseTargetOrReply

test "Targets: carries exactly n addresses" {
    const one: Targets(1) = .{ .hint = null, .addrs = undefined };
    const two: Targets(2) = .{ .hint = null, .addrs = undefined };
    try testing.expectEqual(1, one.addrs.len);
    try testing.expectEqual(2, two.addrs.len);
}

test "parseTargetOrReply: exactly n tokens means no slot number" {
    var t = try TestConn.init();
    defer t.deinit();
    var msg_buf: [256]u8 = undefined;
    var rbuf: [256]u8 = undefined;

    var one = argsOf("set 127.0.0.1:1000");
    const got1 = parseTargetOrReply(1, testing.io, t.conn, &msg_buf, &one, usage_1) orelse return error.TestExpectedTargets;

    try testing.expectEqual(@as(?u32, null), got1.hint);
    try testing.expectEqual(@as(u16, 1000), got1.addrs[0].ip4.port);

    var two = argsOf("edit 127.0.0.1:1000 127.0.0.1:2000");
    const got2 = parseTargetOrReply(2, testing.io, t.conn, &msg_buf, &two, usage_2) orelse return error.TestExpectedTargets;

    try testing.expectEqual(@as(?u32, null), got2.hint);
    try testing.expectEqual(@as(u16, 1000), got2.addrs[0].ip4.port);
    try testing.expectEqual(@as(u16, 2000), got2.addrs[1].ip4.port);

    try testing.expectEqualStrings(TestConn.silence, try t.firstReply(&rbuf));
}

test "parseTargetOrReply: one token more than n makes the first a slot number" {
    var t = try TestConn.init();
    defer t.deinit();
    var msg_buf: [256]u8 = undefined;
    var rbuf: [256]u8 = undefined;

    // Correct format
    var one = argsOf("set 3 127.0.0.1:1000");
    const got1 = parseTargetOrReply(1, testing.io, t.conn, &msg_buf, &one, usage_1) orelse return error.TestExpectedTargets;

    try testing.expectEqual(@as(?u32, 3), got1.hint);
    try testing.expectEqual(@as(u16, 1000), got1.addrs[0].ip4.port);

    // Invalid format
    var one_invalid = argsOf("set 127.0.0.1:1000 127.0.0.1:2000");
    try testing.expect(parseTargetOrReply(1, testing.io, t.conn, &msg_buf, &one_invalid, usage_1) == null);

    const one_reply = try t.firstReply(&rbuf);
    try testing.expect(std.mem.find(u8, one_reply, "not a valid slot number") != null);
    // The offending token is echoed so the operator can see what was read.
    try testing.expect(std.mem.find(u8, one_reply, "127.0.0.1:1000") != null);

    //Correct format
    var two = argsOf("edit 7 127.0.0.1:1000 127.0.0.1:2000");
    const got2 = parseTargetOrReply(2, testing.io, t.conn, &msg_buf, &two, usage_2) orelse return error.TestExpectedTargets;

    try testing.expectEqual(@as(?u32, 7), got2.hint);
    try testing.expectEqual(@as(u16, 1000), got2.addrs[0].ip4.port);
    try testing.expectEqual(@as(u16, 2000), got2.addrs[1].ip4.port);

    try testing.expectEqualStrings(TestConn.silence, try t.firstReply(&rbuf));

    // Incalid format
    var two_invalid = argsOf("edit 127.0.0.1:1000 127.0.0.1:2000 127.0.0.1:3000");
    try testing.expect(parseTargetOrReply(2, testing.io, t.conn, &msg_buf, &two_invalid, usage_2) == null);

    const two_reply = try t.firstReply(&rbuf);
    try testing.expect(std.mem.find(u8, two_reply, "not a valid slot number") != null);
}

test "parseTargetOrReply: the rewind lands after the command word, not at the line start" {
    // The rewind saves `iter.index` instead calling reset(). If it was
    // reset(), `first` would rewind to "rm" and this would fail. The padding is
    // here so the restored index has to land correctly with delimiters as well.
    var t = try TestConn.init();
    defer t.deinit();
    var msg_buf: [256]u8 = undefined;
    var rbuf: [256]u8 = undefined;

    // set/remove (rm)
    var set = argsOf("   rm \t  127.0.0.1:1000   \r\n");
    const set_reply = parseTargetOrReply(1, testing.io, t.conn, &msg_buf, &set, usage_1) orelse return error.TestExpectedTargets;

    try testing.expectEqual(@as(?u32, null), set_reply.hint);
    try testing.expectEqual(@as(u16, 1000), set_reply.addrs[0].ip4.port);
    try testing.expectEqualStrings(TestConn.silence, try t.firstReply(&rbuf));

    // edit
    var edit = argsOf("  edit \t 127.0.0.1:1000   127.0.0.1:2000  \r\n");
    const edit_reply = parseTargetOrReply(2, testing.io, t.conn, &msg_buf, &edit, usage_2) orelse return error.TestExpectedTargets;

    try testing.expectEqual(@as(?u32, null), edit_reply.hint);
    try testing.expectEqual(@as(u16, 1000), edit_reply.addrs[0].ip4.port);
    try testing.expectEqual(@as(u16, 2000), edit_reply.addrs[1].ip4.port);
    try testing.expect(set.peek() == null);
    try testing.expectEqualStrings(TestConn.silence, try t.firstReply(&rbuf));
}

test "parseTargetOrReply: tokens past the last address are left unread" {
    var t = try TestConn.init();
    defer t.deinit();
    var msg_buf: [256]u8 = undefined;
    var rbuf: [256]u8 = undefined;

    var one = argsOf("set 3 127.0.0.1:1000 127.0.0.1:2000 junk");
    const got1 = parseTargetOrReply(1, testing.io, t.conn, &msg_buf, &one, usage_1) orelse return error.TestExpectedTargets;

    try testing.expectEqual(@as(?u32, 3), got1.hint);
    try testing.expectEqual(@as(u16, 1000), got1.addrs[0].ip4.port);
    // Discarded, not consumed. processInput() builds a fresh iterator per line.
    try testing.expect(one.peek() != null);

    var two = argsOf("edit 7 127.0.0.1:1000 127.0.0.1:2000 127.0.0.1:3000");
    const got2 = parseTargetOrReply(2, testing.io, t.conn, &msg_buf, &two, usage_2) orelse return error.TestExpectedTargets;

    try testing.expectEqual(@as(?u32, 7), got2.hint);
    try testing.expectEqual(@as(u16, 2000), got2.addrs[1].ip4.port);
    try testing.expect(two.peek() != null);

    try testing.expectEqualStrings(TestConn.silence, try t.firstReply(&rbuf));
}

test "parseTargetOrReply: too few tokens replies with the caller's usage line" {
    var t = try TestConn.init();
    defer t.deinit();
    var msg_buf: [256]u8 = undefined;
    var rbuf: [256]u8 = undefined;

    // No arguments at all.
    var none1 = argsOf("set");
    try testing.expect(parseTargetOrReply(1, testing.io, t.conn, &msg_buf, &none1, usage_1) == null);
    try testing.expectEqualStrings(usage_1, try t.firstReply(&rbuf));

    var none2 = argsOf("edit");
    try testing.expect(parseTargetOrReply(2, testing.io, t.conn, &msg_buf, &none2, usage_2) == null);
    try testing.expectEqualStrings(usage_2, try t.firstReply(&rbuf));

    // Short edit call
    var short = argsOf("edit 127.0.0.1:1000");
    try testing.expect(parseTargetOrReply(2, testing.io, t.conn, &msg_buf, &short, usage_2) == null);
    try testing.expectEqualStrings(usage_2, try t.firstReply(&rbuf));

    var hinted = argsOf("edit 7 127.0.0.1:1000");
    try testing.expect(parseTargetOrReply(2, testing.io, t.conn, &msg_buf, &hinted, usage_2) == null);
    try testing.expectEqualStrings(usage_2, try t.firstReply(&rbuf));
}

test "parseTargetOrReply: a bad address stops the parse without falling back to usage" {
    var t = try TestConn.init();
    defer t.deinit();
    var msg_buf: [256]u8 = undefined;
    var rbuf: [256]u8 = undefined;

    var iter = argsOf("edit 127.0.0.1:1000 nonsense");
    try testing.expect(parseTargetOrReply(2, testing.io, t.conn, &msg_buf, &iter, usage_2) == null);

    const sent = try t.firstReply(&rbuf);
    try testing.expect(!std.mem.eql(u8, TestConn.silence, sent));
    try testing.expect(!std.mem.eql(u8, usage_2, sent));
}

test "parseTargetOrReply: an out-of-range slot number is rewound, not reported as a slot" {
    var t = try TestConn.init();
    defer t.deinit();
    var msg_buf: [256]u8 = undefined;
    var rbuf: [256]u8 = undefined;

    var invalid1 = argsOf("set 99999999999 127.0.0.1:1000");
    try testing.expect(parseTargetOrReply(1, testing.io, t.conn, &msg_buf, &invalid1, usage_1) == null);

    const resp1 = try t.firstReply(&rbuf);
    try testing.expect(std.mem.find(u8, resp1, "slot") == null);

    var invalid2 = argsOf("edit 99999999999 127.0.0.1:1000  127.0.0.1:1001");
    try testing.expect(parseTargetOrReply(2, testing.io, t.conn, &msg_buf, &invalid2, usage_2) == null);

    const resp2 = try t.firstReply(&rbuf);
    try testing.expect(std.mem.find(u8, resp2, "slot") == null);
}

test "parseTargetOrReply: at n == 2 two addresses can have different family" {
    var t = try TestConn.init();
    defer t.deinit();
    var msg_buf: [256]u8 = undefined;
    var rbuf: [256]u8 = undefined;

    var iter = argsOf("edit 127.0.0.1:1000 [::1]:2000");
    const got = parseTargetOrReply(2, testing.io, t.conn, &msg_buf, &iter, usage_2) orelse return error.TestExpectedTargets;

    try testing.expectEqual(@as(u16, 1000), got.addrs[0].ip4.port);
    try testing.expectEqual(@as(u16, 2000), got.addrs[1].ip6.port);
    try testing.expectEqualStrings(TestConn.silence, try t.firstReply(&rbuf));
}
