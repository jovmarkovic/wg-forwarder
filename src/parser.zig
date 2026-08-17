const std = @import("std");

const Reader = struct {
    parsed: std.json.Parsed(Config),
    buf: []u8,

    /// Helper to get quick access to the config fields
    pub fn config(self: *const Reader) *const Config {
        return &self.parsed.value;
    }

    /// Deinit of the parsed structure and a buffer that holds the data
    pub fn deinit(self: Reader, gpa: std.mem.Allocator) void {
        self.parsed.deinit();
        gpa.free(self.buf);
    }
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
    // Only on error, it holds actual data where parser is pointing to
    errdefer gpa.free(buf);

    var reader = file.reader(io, buf);
    // Read all content of a file into buffer
    try reader.interface.readSliceAll(buf);

    const parsed = try std.json.parseFromSlice(
        Config,
        gpa,
        buf,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed },
    );
    return .{ .parsed = parsed, .buf = buf };
}
