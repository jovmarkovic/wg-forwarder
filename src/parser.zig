const std = @import("std");

const Reader = struct {
    config: Config,
    buf: []u8,
};

const Config = struct {
    client_endpoint: Socket,
    forwarder_socket: Socket,
    server_socket: SrvSocket = .{},
    switcher: Switcher,
    log_level: ?[]const u8 = null,
    admin_console: Admin = .{},

    const Socket = struct {
        address: []const u8,
        port: u16,
    };

    const SrvSocket = struct {
        address: []const u8 = "0.0.0.0",
        port: u16 = 0,
    };

    const Switcher = struct {
        enabled: bool,
        id: usize,
        timer: usize = 0,
        endpoints: []const []const u8,
    };
    const Admin = struct {
        enabled: bool = false,
        address: []const u8 = "127.0.0.1",
        port: u16 = 9000,
    };
};

/// Read and parse the config file
pub fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Reader {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .lock = .exclusive,
    });
    defer file.close(io);

    const buf = try gpa.alloc(u8, try file.length(io));
    var reader = file.reader(io, buf);
    // Read all content of a file into buffer
    try reader.interface.readSliceAll(buf);

    var parsed = try std.json.parseFromSlice(
        Config,
        gpa,
        buf,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    return .{ .config = parsed.value, .buf = buf };
}
