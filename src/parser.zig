const std = @import("std");

const Reader = struct {
    config: Config,
    buf: []u8,
};

const Config = struct {
    client_endpoint: Socket,
    forwarder_socket: Socket,
    server_socket: Socket,
    switcher: Switcher,
    log_level: ?[]const u8 = null,

    const Socket = struct {
        address: []const u8,
        port: u16,
    };

    const Switcher = struct {
        enabled: bool,
        id: usize,
        timer: ?usize = null,
        endpoints: []const []const u8,
    };
};

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) !Reader {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    const stat = try file.stat();
    const size = stat.size;
    defer file.close();
    const buf = try allocator.alloc(u8, size);
    // Discard on success, return error if file.read fails
    _ = try file.read(buf);

    var parsed = try std.json.parseFromSlice(
        Config,
        allocator,
        buf,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    return Reader{ .config = parsed.value, .buf = buf };
}
