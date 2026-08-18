const std = @import("std");
const cfg = @import("parser.zig");

pub const SwitcherState = struct {
    const Self = @This();
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    // Controls; manipulated by mutex
    is_running: bool,
    is_paused: bool = false,
    wake_requested: bool = false,

    // Thread handle to allow re-spawning
    thread: ?std.Thread = null,

    io: std.Io,
    timer: std.atomic.Value(i64) = .init(0), // Just a placeholder, correct value is set in start()
    duration: i64, // manipulated by mutex
    packet_arrived: std.atomic.Value(bool) = .init(true), // Default is true to correctly init wgToServer
    endpoints: *SafeEndpointList,
    current_id: *std.atomic.Value(usize),

    /// Switcher function
    pub fn run(self: *Self) void {
        while (true) {

            // Blocks while paused; null means exit. One lock, one snapshot.
            const duration = self.threadHandler() orelse break;

            const now = nowSeconds(self.io);
            const elapsed = now - self.timer.load(.monotonic);
            std.log.debug("switcher: elapsed={d} duration={d} packet_arrived={}", .{
                elapsed, duration, self.packet_arrived.load(.monotonic),
            });

            // Main check: if packet has arrived
            if (!self.packet_arrived.load(.monotonic)) {
                // Second check: if enough time has passsed before switching
                if (elapsed < duration) {
                    if (!self.waitFor(duration - elapsed)) break;
                    continue;
                }
                // Run actual switch logic
                self.switchEndpoint();
            }

            // Reset time to sync threads
            self.timer.store(nowSeconds(self.io), .monotonic);
            if (!self.waitFor(duration)) break;
        }
    }

    /// Sets the duration of switcher's sleep
    pub fn setDuration(self: *Self, seconds: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.duration = seconds;
        self.wake_requested = true;
        self.cond.broadcast(self.io);
    }

    /// Starts a switcher thread
    pub fn start(self: *Self) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.thread != null) return; // Already running

        //set the states
        self.is_running = true;
        self.is_paused = false;

        // reset the timer upon staring a thread
        self.timer.store(nowSeconds(self.io), .monotonic);

        // Use 'self' as the only argument because the struct has been inited
        self.thread = try std.Thread.spawn(.{}, Self.run, .{self});
    }

    /// Stops a switcher thread
    pub fn stop(self: *Self) void {
        self.mutex.lockUncancelable(self.io);

        self.is_running = false;
        self.wake_requested = true;
        self.cond.broadcast(self.io);
        const handle = self.thread;
        self.thread = null;
        // DO NOT DEFER, IT DEADLOCKS
        self.mutex.unlock(self.io);

        if (handle) |t| t.join();
    }

    /// Resumes a switcher thread
    pub fn play(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.is_paused = false;
        self.cond.signal(self.io); // Wake it up!
    }

    /// Pauses a switcher thread
    pub fn pause(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.is_paused = true;
        self.wake_requested = true;
    }

    /// Function that does the actual switching
    fn switchEndpoint(self: *Self) void {
        const len = self.endpoints.len(self.io);
        if (len == 0) {
            std.log.warn("switcher: endpoint list is empty, nothing to switch to", .{});
            return;
        }
        const new_id = (self.current_id.load(.monotonic) + 1) % len;

        if (self.endpoints.getCopy(self.io, new_id)) |server| {
            self.current_id.store(new_id, .release);
            std.log.info("Switched to ID: {d} address: {f}", .{ new_id, server });
            // Reset packet state
            self.packet_arrived.store(true, .monotonic);
        } else {
            std.log.warn("switcher: failed to get server endpoint!", .{});
        }
    }

    /// Blocks while paused. Returns the current duration, or null if we should exit.
    fn threadHandler(self: *Self) ?i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.is_paused and self.is_running) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        self.wake_requested = false; // don't leave a stale wake for the next waitFor
        if (!self.is_running) return null;
        return self.duration;
    }

    /// Wait up to `duration`, waking early on any state change.
    /// Returns false if the switcher should exit.
    fn waitFor(self: *Self, duration: i64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Create a duration struct
        const dur: std.Io.Clock.Duration = .{ .raw = .fromSeconds(duration), .clock = .awake };
        // Return error.Tiemout based on a duration struct
        const timeout: std.Io.Timeout = .{ .deadline = .fromNow(self.io, dur) };

        while (self.is_running and !self.wake_requested) {
            self.cond.waitTimeout(self.io, &self.mutex, timeout) catch |err| switch (err) {
                error.Timeout => break,
                // For safety in case we switch to ther Io implementation
                error.Canceled => {
                    self.is_running = false;
                    break;
                },
            };
        }
        // Reset wake_requested
        self.wake_requested = false;
        return self.is_running;
    }
};

pub fn wgToServer(
    io: std.Io,
    switcher: *SwitcherState,
    wg_sock: *std.Io.net.Socket,
    serv_sock: *std.Io.net.Socket,
    buf: []u8,
    endpoints: *SafeEndpointList,
    current_id: *std.atomic.Value(usize),
) !void {
    while (true) {

        // --- Handle WireGuard -> server ---
        if (std.Io.net.Socket.receive(wg_sock, io, buf[0..])) |recv| {
            std.log.debug("Received {d} bytes from WireGuard", .{recv.data.len});
            const packet = buf[0..recv.data.len];
            const endpoint = endpoints.getCopy(io, current_id.load(.acquire)) orelse {
                std.log.warn("wgToServer failed to get server endpoint!", .{});
                continue;
            };
            std.log.debug("Trying to send to {f}", .{endpoint});
            if (std.Io.net.Socket.send(serv_sock, io, &endpoint, packet)) {
                // Set a new timer only if packet came from the server and reset packet_arrived
                if (switcher.packet_arrived.load(.monotonic)) {
                    // Reset timer to sync threads and set packet_arrived state
                    switcher.timer.store(nowSeconds(io), .monotonic);
                    switcher.packet_arrived.store(false, .monotonic);
                }
            } else |err| {
                std.log.err("Backend send failed to: {f} {s}", .{ endpoint, @errorName(err) });
            }
        } else |err| {
            return err;
        }
    }
}

pub fn serverToWg(
    io: std.Io,
    wg_addr: std.Io.net.IpAddress,
    switcher: *SwitcherState,
    wg_sock: *std.Io.net.Socket,
    serv_sock: *std.Io.net.Socket,
    srv_buf: []u8,
    endpoints: *SafeEndpointList,
    current_id: *std.atomic.Value(usize),
) !void {
    while (true) {

        // --- Handle server -> WireGuard ---
        if (std.Io.net.Socket.receive(serv_sock, io, srv_buf[0..])) |recv| {
            const addr = recv.from;
            std.log.debug("Received {d} bytes, server: {f}", .{ recv.data.len, addr });
            const packet = srv_buf[0..recv.data.len];
            const endpoint = endpoints.getCopy(io, current_id.load(.acquire)) orelse {
                std.log.warn("serverToWg failed to get server endpoint!", .{});
                continue;
            };
            if (!std.Io.net.IpAddress.eql(&addr, &endpoint)) {
                std.log.warn("Wrong server responding: {f}\nCorrect server: {f}", .{ addr, endpoint });
                // If Received packet comes before sending packet is out at startup, set the correct state and discard it
                switcher.packet_arrived.store(false, .monotonic);
                continue;
            }
            if (std.Io.net.Socket.send(wg_sock, io, &wg_addr, packet)) {
                // Confirm packet came from the server
                switcher.packet_arrived.store(true, .monotonic);
            } else |err| {
                std.log.err("Backend send failed to: {f} {s}", .{ wg_addr, @errorName(err) });
            }
        } else |err| {
            return err;
        }
    }
}

pub const SafeEndpointList = struct {
    const Self = @This();
    lock: std.Io.RwLock = .init,
    list: std.ArrayList(std.Io.net.IpAddress) = .empty,

    pub fn lockSharedUncancelable(self: *Self, io: std.Io) void {
        self.lock.lockSharedUncancelable(io);
    }

    pub fn unlockShared(self: *Self, io: std.Io) void {
        self.lock.unlockShared(io);
    }

    /// Only use while locked!
    /// Get the raw items slice
    pub fn getItems(self: *Self) []std.Io.net.IpAddress {
        return self.list.items;
    }

    /// Use this in network threads (fast, non-blocking for other readers)
    pub fn getCopy(self: *Self, io: std.Io, index: usize) ?std.Io.net.IpAddress {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        if (index >= self.list.items.len) return null;
        return self.list.items[index];
    }

    /// Only use while locked!
    /// Use this in network threads (fast, non-blocking for other readers)
    pub fn getCopyUnsafe(self: *Self, index: usize) std.Io.net.IpAddress {
        return self.list.items[index];
    }

    /// Use this in Admin thread to add
    pub fn add(self: *Self, io: std.Io, gpa: std.mem.Allocator, addr: std.Io.net.IpAddress) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        try self.list.append(gpa, addr);
    }

    /// Only use while locked!
    /// Use this in Admin thread to add
    pub fn addUnsafe(self: *Self, gpa: std.mem.Allocator, addr: std.Io.net.IpAddress) !void {
        try self.list.append(gpa, addr);
    }

    /// Use this in Admin thread to edit
    pub fn edit(self: *Self, io: std.Io, index: usize, new_addr: std.Io.net.IpAddress) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        if (index >= self.list.items.len) return error.IndexOutOfBounds;

        self.list.items[index] = new_addr;
    }

    /// Use this in Admin thread to pop last endpoint
    pub fn pop(self: *Self, io: std.Io) ?std.Io.net.IpAddress {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        return self.list.pop();
    }

    /// Only use while locked!
    /// Use this in Admin thread to pop last endpoint
    pub fn popUnsafe(self: *Self) ?std.Io.net.IpAddress {
        return self.list.pop();
    }

    /// Use this in Admin thread to remove endpoint at specific index
    pub fn orderedRemove(self: *Self, io: std.Io, index: usize) !std.Io.net.IpAddress {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        if (index >= self.list.items.len) return error.IndexOutOfBounds;
        return self.list.orderedRemove(index);
    }

    /// Only use while locked!
    /// Use this in Admin thread to remove endpoint at specific index
    pub fn orderedRemoveUnsafe(self: *Self, index: usize) std.Io.net.IpAddress {
        return self.list.orderedRemove(index);
    }

    /// Only use while locked!
    /// Use this to get current array length
    pub fn lenUnsafe(self: *Self) usize {
        return self.list.items.len;
    }
    /// Use this to get current array length
    pub fn len(self: *Self, io: std.Io) usize {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.list.items.len;
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        self.list.deinit(gpa);
    }
};

/// Helper function returning monotonic seconds for measuring intervals.
fn nowSeconds(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.toSeconds();
}
