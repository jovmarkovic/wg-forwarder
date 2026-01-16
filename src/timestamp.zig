const std = @import("std");
const day_seconds = std.time.epoch.DaySeconds;
const heap = std.heap;
const clock = std.Io.Clock;
const epoch_seconds = std.time.epoch.EpochSeconds;
const day_epoch_seconds = std.time.epoch.DaySeconds;
const epoch_day = std.time.epoch.EpochDay;
const epoch_year_day = std.time.epoch.YearAndDay;

const real_clock = clock.real;

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

fn getTimeParts(timestamp: std.Io.Timestamp) TimeParts {
    const sec = std.Io.Timestamp.toSeconds(timestamp);
    const sec_u: u64 = @intCast(sec);
    const day_sec = epoch_seconds.getDaySeconds(epoch_seconds{ .secs = sec_u });

    const hrs = day_epoch_seconds.getHoursIntoDay(day_sec);
    const mins = day_epoch_seconds.getMinutesIntoHour(day_sec);
    const secs = day_epoch_seconds.getSecondsIntoMinute(day_sec);

    const day = epoch_seconds.getEpochDay(epoch_seconds{ .secs = sec_u });
    const yr_day = epoch_day.calculateYearDay(day);
    const mon_day = epoch_year_day.calculateMonthDay(yr_day);

    const msec = @rem(std.Io.Timestamp.toMilliseconds(timestamp), 1000);

    return TimeParts{
        .year = yr_day.year,
        .month_index = mon_day.month.numeric(),
        .day = mon_day.day_index + 1,
        .hour = hrs,
        .min = mins,
        .sec = secs,
        .msec = @intCast(msec),
    };
}

const FormatMode = enum {
    now,
    syslog,
};

pub const Time = struct {
    const Self = @This();
    io: std.Io,

    pub fn create(io: std.Io) Time {
        return Time{ .io = io };
    }

    /// Entry point for formatting. Use as: .{time.fmt(.now)}
    pub fn fmt(self: Self, mode: FormatMode) Formatter {
        return .{ .time = self, .mode = mode };
    }

    const Formatter = struct {
        time: Time,
        mode: FormatMode,

        pub fn format(
            self: Formatter,
            writer: *std.Io.Writer,
        ) !void {
            const timestamp = clock.now(
                real_clock,
                self.time.io,
            ) catch |e|
                std.debug.panic("failed to get clock: {any}\n", .{e});

            const parts = getTimeParts(timestamp);

            switch (self.mode) {
                .now => {
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

    // Setup IO (Required for clock.now)
    var io_init = std.Io.Threaded.init(alloc, .{ .environ = .empty });
    const io = io_init.io();

    //  Create the Time instance
    const tnow = Time.create(io);

    // Test 'now()'
    const now = tnow.fmt(.now);
    const buf_now = try std.fmt.allocPrint(alloc, "{f}\n", .{now});
    defer alloc.free(buf_now);
    std.debug.assert(buf_now.len == 24);

    //  Test 'syslog()'
    const syslog = tnow.fmt(.syslog);
    const buf_syslog = try std.fmt.allocPrint(alloc, "{f}\n", .{syslog});
    defer alloc.free(buf_syslog);
    std.debug.assert(buf_syslog.len == 16);
}
