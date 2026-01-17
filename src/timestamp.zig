const std = @import("std");
const epoch = std.time.epoch;
const heap = std.heap;

const MONTH_NAMES = [12][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

const TimeParts = struct {
    year: u16,
    month_index: u4, // 0 = Jan
    day: u5, // 1..31
    hour: u5,
    min: u6,
    sec: u6,
    msec: u16,
};

fn getTimeParts() TimeParts {
    // Get timestamp in milliseconds
    const ms_timestamp = std.time.milliTimestamp();

    // Extract seconds and remaining milliseconds
    const sec_u: u64 = @intCast(@divTrunc(ms_timestamp, 1000));
    const msec = @mod(ms_timestamp, 1000);

    // Initialize epoch utility structures
    const epoch_seconds = epoch.EpochSeconds{ .secs = sec_u };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    // Calculate year, month, and day
    const yr_day = epoch_day.calculateYearDay();
    const mon_day = yr_day.calculateMonthDay();

    return TimeParts{
        .year = yr_day.year,
        .month_index = mon_day.month.numeric(),
        .day = mon_day.day_index + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .min = day_seconds.getMinutesIntoHour(),
        .sec = day_seconds.getSecondsIntoMinute(),
        .msec = @intCast(msec),
    };
}

const FormatMode = enum { full, syslog };

pub const Time = struct {
    /// Entry point for formatting. Use as: .{time.fmt(.now)}
    pub fn fmt(mode: FormatMode) Formatter {
        return .{ .mode = mode };
    }
    const Formatter = struct {
        mode: FormatMode,

        pub fn format(
            self: Formatter,
            writer: *std.Io.Writer,
        ) !void {
            const parts = getTimeParts();

            switch (self.mode) {
                .full => {
                    try writer.print("{d}-{:0>2}-{:0>2} {:0>2}:{:0>2}:{:0>2}.{:0>3}", .{
                        parts.year,
                        parts.month_index,
                        parts.day,
                        parts.hour,
                        parts.min,
                        parts.sec,
                        parts.msec,
                    });
                },
                .syslog => {
                    try writer.print("{s} {:0>2} {:0>2}:{:0>2}:{:0>2}", .{
                        MONTH_NAMES[parts.month_index - 1],
                        parts.day,
                        parts.hour,
                        parts.min,
                        parts.sec,
                    });
                },
            }
        }
    };
};

// ===========================================================
// ====================unit test==============================
// ===========================================================

test "Time struct formatting" {
    var arena_allocator = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena_allocator.deinit();
    const alloc = arena_allocator.allocator();

    // Test 'now()'
    const now = Time.fmt(.full);
    const buf_now = try std.fmt.allocPrint(alloc, "{f}\n", .{now});
    defer alloc.free(buf_now);
    std.debug.assert(buf_now.len == 24);

    //  Test 'syslog()'
    const syslog = Time.fmt(.syslog);
    const buf_syslog = try std.fmt.allocPrint(alloc, "{f}\n", .{syslog});
    defer alloc.free(buf_syslog);
    std.debug.assert(buf_syslog.len == 16);
}
