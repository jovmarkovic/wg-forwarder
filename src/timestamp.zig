const std = @import("std");
const heap = std.heap;
const clock = std.Io.Clock;

const MONTH_NAMES = [12][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

const TimeParts = struct {
    year: u16,
    month: u4, // 1 = Jan
    day: u5, // 1..31
    sub_day: SubDay,
    const SubDay = struct {
        hour: u5,
        min: u6,
        sec: u6,
        ms: u16,
    };
};

fn getSubDayParts(total_ms: i64) TimeParts.SubDay {
    // Use modulo to get the remainer of the day
    const day_ms = @mod(total_ms, std.time.ms_per_day);

    // Calcute hours
    const hour = @divTrunc(day_ms, std.time.ms_per_hour);
    const rem_h = @mod(day_ms, std.time.ms_per_hour);
    // Use modulo from hours to caclulate minutes
    const min = @divTrunc(rem_h, std.time.ms_per_min);
    const rem_m = @mod(rem_h, std.time.ms_per_min);
    // Use modulo from minutes to calculate seconds
    const sec = @divTrunc(rem_m, std.time.ms_per_s);
    // Use modulo from seconds to calculate milliseconds
    const ms = @mod(rem_m, std.time.ms_per_s);

    return .{
        .hour = @intCast(hour),
        .min = @intCast(min),
        .sec = @intCast(sec),
        .ms = @intCast(ms),
    };
}

// Neri-Schneider Gregorian Constants
const DAYS_PER_400_YEARS = 146097;
const PRECISION_MULTIPLIER = 2939745;

fn getTimeParts(timestamp: std.Io.Timestamp) TimeParts {
    const total_ms = timestamp.toMilliseconds();

    // --- Time Component Calculation ---
    // Extract sub-day components (HH:MM:SS.ms)
    const sub_day = getSubDayParts(total_ms);

    // Convert total time to days since the Unix Epoch (1970-01-01)
    const total_secs = @divTrunc(total_ms, std.time.ms_per_s);
    const days_since_epoch = @divTrunc(total_secs, std.time.s_per_day);

    // --- Date Component Calculation (Neri/Schneider) ---
    // 1. Shift the Epoch: Move from 1970-01-01 to a safe 400-year cycle boundary.
    // 82 cycles (82 * 400 years) ensures the algorithm works for dates far in the past.
    const cycle_shift: u32 = 82;
    const year_offset: u32 = 400 * cycle_shift;

    // 719468 is the offset required to shift the Unix Epoch (1970)
    // to a range where the algorithmic year starts on March 1st.
    const rd_offset: u32 = 719468 + DAYS_PER_400_YEARS * cycle_shift;

    // Shift our current days into the algorithmic range
    const shifted_rd: u32 = @as(u32, @intCast(days_since_epoch)) +% rd_offset;

    // 2. Century calculation: extract the 400-year cycle and century within it
    const n1 = 4 * shifted_rd + 3;
    const century = n1 / DAYS_PER_400_YEARS;
    const days_since_century = (n1 % DAYS_PER_400_YEARS) / 4;

    // 3. Year calculation: Uses a fixed-point multiplier to find the year within the century
    const n2 = 4 * days_since_century + 3;
    const pm: u64 = @as(u64, PRECISION_MULTIPLIER) * n2;

    const year_within_century: u32 = @intCast(pm / 4294967296);
    const day_of_year_raw: u32 = @intCast((pm % 4294967296) / PRECISION_MULTIPLIER / 4);
    const absolute_year = 100 * century + year_within_century;

    // 4. Month and day calculation using fractional month mapping
    // 2141 and 197913 are constants that map day-of-year to month lengths
    const month_computation = 2141 * day_of_year_raw + 197913;
    const month_raw = month_computation / 65536;
    const day_raw = (month_computation % 65536) / 2141;

    // 5. The algorithm treats the year as starting on March 1st.
    // We correct for dates in Jan/Feb (day_of_year >= 306) and subtract the cycle shift.
    const is_after_feb = (day_of_year_raw >= 306);
    const final_year: i32 = @intCast(@as(i32, @bitCast(absolute_year -% year_offset)) + @intFromBool(is_after_feb));
    const final_month = month_raw - (if (is_after_feb) @as(u32, 12) else 0);

    // Return packed TimeParts
    return .{
        .year = @intCast(final_year),
        .month = @intCast(final_month),
        .day = @intCast(day_raw + 1), //1-based index
        .sub_day = sub_day,
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
            const timestamp = clock.now(.real, self.time.io);

            const parts = getTimeParts(timestamp);

            switch (self.mode) {
                .now => {
                    try writer.print("{d}-{:0>2}-{:0>2} {:0>2}:{:0>2}:{:0>2}.{:0>3}", .{
                        parts.year,
                        parts.month,
                        parts.day,
                        parts.sub_day.hour,
                        parts.sub_day.min,
                        parts.sub_day.sec,
                        parts.sub_day.ms,
                    });
                },
                .syslog => {
                    try writer.print("{s} {:0>2} {:0>2}:{:0>2}:{:0>2}", .{
                        MONTH_NAMES[parts.month - 1], // 0-based index
                        parts.day,
                        parts.sub_day.hour,
                        parts.sub_day.min,
                        parts.sub_day.sec,
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
    const buf_now = try std.fmt.allocPrint(alloc, "{f}", .{now});
    defer alloc.free(buf_now);
    std.debug.assert(buf_now.len == 23);
    std.debug.print("{s}\n", .{buf_now});

    //  Test 'syslog()'
    const syslog = tnow.fmt(.syslog);
    const buf_syslog = try std.fmt.allocPrint(alloc, "{f}", .{syslog});
    defer alloc.free(buf_syslog);
    std.debug.assert(buf_syslog.len == 15);
    std.debug.print("{s}\n", .{buf_syslog});
}
