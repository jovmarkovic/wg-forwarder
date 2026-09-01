const std = @import("std");
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

/// `day_ms` MUST already be reduced to 0..ms_per_day-1. `getTimeParts` does that
/// with a floored division it needs anyway, so the reduction is free here — and
/// taking u32 keeps every division below 32-bit rather than 64.
fn getSubDayParts(day_ms: u32) TimeParts.SubDay {
    // Calcute hours
    const hour = day_ms / std.time.ms_per_hour;
    const rem_h = day_ms % std.time.ms_per_hour;
    // Use remainder from hours to caclulate minutes
    const min = rem_h / std.time.ms_per_min;
    const rem_m = rem_h % std.time.ms_per_min;
    // Use remainder from minutes to calculate seconds
    const sec = rem_m / std.time.ms_per_s;
    // Use remainder from seconds to calculate milliseconds
    const ms = rem_m % std.time.ms_per_s;

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

/// Split timestamp into calendar components.
/// Any timestamp whose year lands in 0..65535 is valid.
/// Below year 1 the `@intCast` on the way out will panic.
/// A clock would have to be wrong by two millennia to get there.
fn getTimeParts(timestamp: std.Io.Timestamp) TimeParts {
    const total_ms = timestamp.toMilliseconds();

    // Day / time-of-day split:
    // One floored division yields both the day number and the offset inside that
    // day. @divTrunc rounds toward zero, which puts a pre-epoch timestamp on the wrong side of midnight.
    // Time-of-day (already floored) reports the right clock.
    const days_since_epoch = @divFloor(total_ms, std.time.ms_per_day);
    const day_ms: u32 = @intCast(total_ms - days_since_epoch * std.time.ms_per_day);

    // Extract sub-day components (HH:MM:SS.ms)
    const sub_day = getSubDayParts(day_ms);

    // Neri/Schneider date component calculation:
    // Shift the Epoch: Move from 1970-01-01 to a safe 400-year cycle boundary.
    // 82 cycles (82 * 400 years) ensures the algorithm works for dates far in the past.
    const cycle_shift: u32 = 82;
    const year_offset: u32 = 400 * cycle_shift;

    // 719468 is the offset shifting the Unix Epoch (1970)
    // to a range where the algorithmic year starts on March 1st.
    const rd_offset: u32 = 719468 + DAYS_PER_400_YEARS * cycle_shift;

    // Shift timestamp days into the algorithmic range:
    // The addition happens in i64. A negative day count is lifted into range before the cast instead being rejected by it.
    // rd_offset buys ~34,700 year range below the epoch. @intCast then binds the far end instead of wrapping.
    const shifted_rd: u32 = @intCast(days_since_epoch + rd_offset);

    // Century calculation: extract the 400-year cycle and century within it
    const n1 = 4 * shifted_rd + 3;
    const century = n1 / DAYS_PER_400_YEARS;
    const days_since_century = (n1 % DAYS_PER_400_YEARS) / 4;

    // Year calculation: Uses a fixed-point multiplier to find the year within the century
    const n2 = 4 * days_since_century + 3;
    const pm: u64 = @as(u64, PRECISION_MULTIPLIER) * n2;

    const year_within_century: u32 = @intCast(pm / 4294967296);
    const day_of_year_raw: u32 = @intCast((pm % 4294967296) / PRECISION_MULTIPLIER / 4);
    const absolute_year = 100 * century + year_within_century;

    // Month and day calculation using fractional month mapping:
    // 2141 and 197913 are constants that map day-of-year to month lengths
    const month_computation = 2141 * day_of_year_raw + 197913;
    const month_raw = month_computation / 65536;
    const day_raw = (month_computation % 65536) / 2141;

    // The algorithm treats the year as starting on March 1st.
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

pub const FormatMode = enum {
    now,
    syslog,
};

pub const Time = struct {
    const Self = @This();
    io: std.Io,

    pub fn create(io: std.Io) Time {
        return .{ .io = io };
    }

    /// Entry point for formatting. Use as: .{time.fmt(.now)}
    /// Reads the wall clock at the moment the writer formats it.
    pub fn fmt(self: Self, mode: FormatMode) Formatter {
        return .{ .time = self, .mode = mode, .at = null };
    }

    /// Same as `fmt`, but accepts a timestamp instead of setting one.
    /// Deterministic, can be used in tests to check formatting.
    pub fn fmtAt(self: Self, mode: FormatMode, at: std.Io.Timestamp) Formatter {
        return .{ .time = self, .mode = mode, .at = at };
    }

    const Formatter = struct {
        time: Time,
        mode: FormatMode,
        /// When null, formatter sets it's own timestamp.
        at: ?std.Io.Timestamp = null,

        pub fn format(
            self: Formatter,
            writer: *std.Io.Writer,
        ) !void {
            const timestamp = self.at orelse clock.now(.real, self.time.io);

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

/// Monotonic seconds, excludes OS suspended time.
/// Used for correct interval tracking
pub fn nowSeconds(io: std.Io) i64 {
    return clock.Timestamp.now(io, .awake).raw.toSeconds();
}

// Tests
// Pre-epoch timestamps are covered. One floored division now feeds both the
// day number and the time of day, and the rd_offset shift happens in i64, so
// dates below 1970 are ordinary inputs.

const testing = std.testing;

const show_stamp = true;

/// Build a `Timestamp` from milliseconds since the Unix epoch. No `Io`.
fn tsFromMs(ms: i64) std.Io.Timestamp {
    return .fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms);
}

fn partsOfMs(ms: i64) TimeParts {
    return getTimeParts(tsFromMs(ms));
}

const Case = struct {
    ms: i64,
    y: u16,
    mo: u4,
    d: u5,
    h: u5,
    mi: u6,
    s: u6,
    milli: u16,
    note: []const u8,
};

fn expectCase(c: Case) !void {
    const p = partsOfMs(c.ms);
    const got: [7]u64 = .{ p.year, p.month, p.day, p.sub_day.hour, p.sub_day.min, p.sub_day.sec, p.sub_day.ms };
    const want: [7]u64 = .{ c.y, c.mo, c.d, c.h, c.mi, c.s, c.milli };
    if (!std.mem.eql(u64, &got, &want)) {
        std.debug.print(
            \\
            \\case: {s}  (ms = {d})
            \\  want {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}
            \\   got {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}
            \\
        , .{
            c.note,  c.ms,
            want[0], want[1],
            want[2], want[3],
            want[4], want[5],
            want[6], got[0],
            got[1],  got[2],
            got[3],  got[4],
            got[5],  got[6],
        });
        return error.TestUnexpectedResult;
    }
}

// getTimeParts

test "getTimeParts: known timestamps across leap rules and boundaries" {
    const cases = [_]Case{
        .{ .ms = 0, .y = 1970, .mo = 1, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "the epoch itself" },
        .{ .ms = 1, .y = 1970, .mo = 1, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 1, .note = "one millisecond in" },
        .{ .ms = 86399999, .y = 1970, .mo = 1, .d = 1, .h = 23, .mi = 59, .s = 59, .milli = 999, .note = "last instant of day one" },
        .{ .ms = 86400000, .y = 1970, .mo = 1, .d = 2, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "first instant of day two" },
        .{ .ms = 5054400000, .y = 1970, .mo = 2, .d = 28, .h = 12, .mi = 0, .s = 0, .milli = 0, .note = "1970 Feb 28" },
        .{ .ms = 5097600000, .y = 1970, .mo = 3, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1970 Mar 1 - the algorithm's year boundary" },
        .{ .ms = 31535999999, .y = 1970, .mo = 12, .d = 31, .h = 23, .mi = 59, .s = 59, .milli = 999, .note = "last instant of 1970" },
        .{ .ms = 31536000000, .y = 1971, .mo = 1, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "first instant of 1971" },
        .{ .ms = 36547200000, .y = 1971, .mo = 2, .d = 28, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "non-leap Feb 28" },
        .{ .ms = 36633600000, .y = 1971, .mo = 3, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "non-leap Mar 1 - no Feb 29 to skip" },
        .{ .ms = 68083200000, .y = 1972, .mo = 2, .d = 28, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "first leap year after the epoch, Feb 28" },
        .{ .ms = 68214896789, .y = 1972, .mo = 2, .d = 29, .h = 12, .mi = 34, .s = 56, .milli = 789, .note = "first leap day after the epoch" },
        .{ .ms = 68256000000, .y = 1972, .mo = 3, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "day after the first leap day" },
        .{ .ms = 94694399999, .y = 1972, .mo = 12, .d = 31, .h = 23, .mi = 59, .s = 59, .milli = 999, .note = "end of a leap year" },
        .{ .ms = 946684799999, .y = 1999, .mo = 12, .d = 31, .h = 23, .mi = 59, .s = 59, .milli = 999, .note = "Y2K eve" },
        .{ .ms = 946684800000, .y = 2000, .mo = 1, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "Y2K" },
        .{ .ms = 951696000000, .y = 2000, .mo = 2, .d = 28, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "2000 Feb 28" },
        .{ .ms = 951825600000, .y = 2000, .mo = 2, .d = 29, .h = 12, .mi = 0, .s = 0, .milli = 0, .note = "2000 Feb 29 - divisible by 400, is a leap year" },
        .{ .ms = 951868800000, .y = 2000, .mo = 3, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "2000 Mar 1" },
        .{ .ms = 1709251199500, .y = 2024, .mo = 2, .d = 29, .h = 23, .mi = 59, .s = 59, .milli = 500, .note = "2024 leap day, last half second" },
        .{ .ms = 2147483647000, .y = 2038, .mo = 1, .d = 19, .h = 3, .mi = 14, .s = 7, .milli = 0, .note = "signed 32-bit second rollover" },
        .{ .ms = 2147483648000, .y = 2038, .mo = 1, .d = 19, .h = 3, .mi = 14, .s = 8, .milli = 0, .note = "one second past the rollover" },
        .{ .ms = 4102444799999, .y = 2099, .mo = 12, .d = 31, .h = 23, .mi = 59, .s = 59, .milli = 999, .note = "end of the 21st century" },
        .{ .ms = 4107456000000, .y = 2100, .mo = 2, .d = 28, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "2100 Feb 28" },
        .{ .ms = 4107542400000, .y = 2100, .mo = 3, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "2100 Mar 1 - divisible by 100, not a leap year" },
        .{ .ms = 13574563200000, .y = 2400, .mo = 2, .d = 29, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "2400 Feb 29 - divisible by 400 again" },
        .{ .ms = 978307200000, .y = 2001, .mo = 1, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "start of a century-ish year" },
        .{ .ms = 1465979445123, .y = 2016, .mo = 6, .d = 15, .h = 8, .mi = 30, .s = 45, .milli = 123, .note = "an ordinary instant" },
        .{ .ms = 253402300799999, .y = 9999, .mo = 12, .d = 31, .h = 23, .mi = 59, .s = 59, .milli = 999, .note = "the last four-digit year" },
    };
    for (cases) |c| try expectCase(c);
}

test "getTimeParts: every month of a non-leap year starts on the right day" {
    // 1971 is the first full non-leap year after the epoch. Walking the first of
    // each month checks the 2141/197913 month mapping in both halves of the
    // algorithm's March-to-February year.
    const firsts = [_]Case{
        .{ .ms = 31536000000, .y = 1971, .mo = 1, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1971-01-01" },
        .{ .ms = 34214400000, .y = 1971, .mo = 2, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1971-02-01" },
        .{ .ms = 36633600000, .y = 1971, .mo = 3, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1971-03-01" },
        .{ .ms = 39312000000, .y = 1971, .mo = 4, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1971-04-01" },
        .{ .ms = 41904000000, .y = 1971, .mo = 5, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1971-05-01" },
        .{ .ms = 44582400000, .y = 1971, .mo = 6, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1971-06-01" },
        .{ .ms = 47174400000, .y = 1971, .mo = 7, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1971-07-01" },
        .{ .ms = 49852800000, .y = 1971, .mo = 8, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1971-08-01" },
        .{ .ms = 52531200000, .y = 1971, .mo = 9, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1971-09-01" },
        .{ .ms = 55123200000, .y = 1971, .mo = 10, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1971-10-01" },
        .{ .ms = 57801600000, .y = 1971, .mo = 11, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1971-11-01" },
        .{ .ms = 60393600000, .y = 1971, .mo = 12, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1971-12-01" },
    };
    for (firsts) |c| try expectCase(c);
}

test "getTimeParts: every month of a leap year starts on the right day" {
    const firsts = [_]Case{
        .{ .ms = 63072000000, .y = 1972, .mo = 1, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1972-01-01" },
        .{ .ms = 65750400000, .y = 1972, .mo = 2, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1972-02-01" },
        .{ .ms = 68256000000, .y = 1972, .mo = 3, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1972-03-01" },
        .{ .ms = 70934400000, .y = 1972, .mo = 4, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1972-04-01" },
        .{ .ms = 73526400000, .y = 1972, .mo = 5, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1972-05-01" },
        .{ .ms = 76204800000, .y = 1972, .mo = 6, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1972-06-01" },
        .{ .ms = 78796800000, .y = 1972, .mo = 7, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1972-07-01" },
        .{ .ms = 81475200000, .y = 1972, .mo = 8, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1972-08-01" },
        .{ .ms = 84153600000, .y = 1972, .mo = 9, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1972-09-01" },
        .{ .ms = 86745600000, .y = 1972, .mo = 10, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1972-10-01" },
        .{ .ms = 89424000000, .y = 1972, .mo = 11, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1972-11-01" },
        .{ .ms = 92016000000, .y = 1972, .mo = 12, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1972-12-01" },
    };
    for (firsts) |c| try expectCase(c);
}

test "getTimeParts: consecutive days never skip or repeat a date" {
    var ms: i64 = 63072000000; // 1972-01-01
    var prev = partsOfMs(ms);

    const month_len = [_]u5{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var n: usize = 0;
    while (n < 800) : (n += 1) {
        ms += std.time.ms_per_day;
        const cur = partsOfMs(ms);

        const leap = (prev.year % 4 == 0 and prev.year % 100 != 0) or prev.year % 400 == 0;
        var len = month_len[prev.month - 1];
        if (prev.month == 2 and leap) len = 29;

        if (prev.day < len) {
            try testing.expectEqual(prev.year, cur.year);
            try testing.expectEqual(prev.month, cur.month);
            try testing.expectEqual(prev.day + 1, cur.day);
        } else if (prev.month < 12) {
            try testing.expectEqual(prev.year, cur.year);
            try testing.expectEqual(prev.month + 1, cur.month);
            try testing.expectEqual(@as(u5, 1), cur.day);
        } else {
            try testing.expectEqual(prev.year + 1, cur.year);
            try testing.expectEqual(@as(u4, 1), cur.month);
            try testing.expectEqual(@as(u5, 1), cur.day);
        }
        prev = cur;
    }
}

test "getTimeParts: sub-day fields are independent of the date" {
    const tod: i64 = 13 * std.time.ms_per_hour + 37 * std.time.ms_per_min + 42 * std.time.ms_per_s + 123;
    for ([_]i64{ 0, 946684800000, 4107456000000 }) |day_start| {
        const p = partsOfMs(day_start + tod);
        try testing.expectEqual(@as(u5, 13), p.sub_day.hour);
        try testing.expectEqual(@as(u6, 37), p.sub_day.min);
        try testing.expectEqual(@as(u6, 42), p.sub_day.sec);
        try testing.expectEqual(@as(u16, 123), p.sub_day.ms);
    }
}

// getSubDayParts

test "getSubDayParts: boundaries inside a day" {
    const rows = [_]struct { ms: u32, h: u5, mi: u6, s: u6, milli: u16 }{
        .{ .ms = 0, .h = 0, .mi = 0, .s = 0, .milli = 0 },
        .{ .ms = 1, .h = 0, .mi = 0, .s = 0, .milli = 1 },
        .{ .ms = 999, .h = 0, .mi = 0, .s = 0, .milli = 999 },
        .{ .ms = 1000, .h = 0, .mi = 0, .s = 1, .milli = 0 },
        .{ .ms = 59_999, .h = 0, .mi = 0, .s = 59, .milli = 999 },
        .{ .ms = 60_000, .h = 0, .mi = 1, .s = 0, .milli = 0 },
        .{ .ms = 3_599_999, .h = 0, .mi = 59, .s = 59, .milli = 999 },
        .{ .ms = 3_600_000, .h = 1, .mi = 0, .s = 0, .milli = 0 },
        .{ .ms = 43_200_000, .h = 12, .mi = 0, .s = 0, .milli = 0 },
        .{ .ms = 86_399_999, .h = 23, .mi = 59, .s = 59, .milli = 999 },
    };
    for (rows) |r| {
        const p = getSubDayParts(r.ms);
        try testing.expectEqual(r.h, p.hour);
        try testing.expectEqual(r.mi, p.min);
        try testing.expectEqual(r.s, p.sec);
        try testing.expectEqual(r.milli, p.ms);
    }
}

test "getTimeParts: pre-epoch timestamps reduce to a valid time of day" {
    // The reduction now lives in getTimeParts and this is where it gets checked:
    // a negative millisecond count must still land inside 00:00:00.000 ..
    // 23:59:59.999 and name the day that time belongs to.
    const a = partsOfMs(-1);
    try testing.expectEqual(@as(u16, 1969), a.year);
    try testing.expectEqual(@as(u5, 31), a.day);
    try testing.expectEqual(@as(u5, 23), a.sub_day.hour);
    try testing.expectEqual(@as(u16, 999), a.sub_day.ms);

    const b = partsOfMs(-std.time.ms_per_day);
    try testing.expectEqual(@as(u16, 1969), b.year);
    try testing.expectEqual(@as(u5, 31), b.day);
    try testing.expectEqual(@as(u5, 0), b.sub_day.hour);
    try testing.expectEqual(@as(u16, 0), b.sub_day.ms);
}

test "getSubDayParts: every hour and minute of a day round-trips" {
    var h: u5 = 0;
    while (h < 24) : (h += 1) {
        var mi: u6 = 0;
        while (mi < 60) : (mi += 1) {
            const ms = @as(u32, h) * std.time.ms_per_hour + @as(u32, mi) * std.time.ms_per_min + 30_500;
            const p = getSubDayParts(ms);
            try testing.expectEqual(h, p.hour);
            try testing.expectEqual(mi, p.min);
            try testing.expectEqual(@as(u6, 30), p.sec);
            try testing.expectEqual(@as(u16, 500), p.ms);
        }
    }
}

// month names

test "MONTH_NAMES: twelve entries, indexed by month - 1" {
    try testing.expectEqual(@as(usize, 12), MONTH_NAMES.len);
    for (MONTH_NAMES) |m| try testing.expectEqual(@as(usize, 3), m.len);

    // 2023 is an ordinary year; the 15th of each month avoids every edge case.
    const fifteenths = [_]struct { ms: i64, name: []const u8 }{
        .{ .ms = 1673740800000, .name = "Jan" },
        .{ .ms = 1676419200000, .name = "Feb" },
        .{ .ms = 1678838400000, .name = "Mar" },
        .{ .ms = 1681516800000, .name = "Apr" },
        .{ .ms = 1684108800000, .name = "May" },
        .{ .ms = 1686787200000, .name = "Jun" },
        .{ .ms = 1689379200000, .name = "Jul" },
        .{ .ms = 1692057600000, .name = "Aug" },
        .{ .ms = 1694736000000, .name = "Sep" },
        .{ .ms = 1697328000000, .name = "Oct" },
        .{ .ms = 1700006400000, .name = "Nov" },
        .{ .ms = 1702598400000, .name = "Dec" },
    };
    for (fifteenths, 1..) |f, expected_month| {
        const p = partsOfMs(f.ms);
        try testing.expectEqual(@as(u4, @intCast(expected_month)), p.month);
        try testing.expectEqual(@as(u5, 15), p.day);
        try testing.expectEqualStrings(f.name, MONTH_NAMES[p.month - 1]);
    }
}

// Formatter

fn expectShape(template: []const u8, out: []const u8) !void {
    try testing.expectEqual(template.len, out.len);
    for (template, out) |t, c| switch (t) {
        'd' => try testing.expect(std.ascii.isDigit(c)),
        'C' => try testing.expect(std.ascii.isUpper(c)),
        'c' => try testing.expect(std.ascii.isLower(c)),
        else => try testing.expectEqual(t, c),
    };
}

test "Formatter: exact output at known timestamps" {
    const t = Time.create(testing.io);

    const rows = [_]struct { ms: i64, now: []const u8, syslog: []const u8 }{
        .{ .ms = 0, .now = "1970-01-01 00:00:00.000", .syslog = "Jan 01 00:00:00" },
        .{ .ms = 86399999, .now = "1970-01-01 23:59:59.999", .syslog = "Jan 01 23:59:59" },
        .{ .ms = 951825600000, .now = "2000-02-29 12:00:00.000", .syslog = "Feb 29 12:00:00" },
        .{ .ms = 1702598400000, .now = "2023-12-15 00:00:00.000", .syslog = "Dec 15 00:00:00" },
        .{ .ms = 1709251199500, .now = "2024-02-29 23:59:59.500", .syslog = "Feb 29 23:59:59" },
        .{ .ms = 4107542400000, .now = "2100-03-01 00:00:00.000", .syslog = "Mar 01 00:00:00" },
        .{ .ms = -1000, .now = "1969-12-31 23:59:59.000", .syslog = "Dec 31 23:59:59" },
    };

    for (rows) |r| {
        var buf: [64]u8 = undefined;

        var w = std.Io.Writer.fixed(&buf);
        try w.print("{f}", .{t.fmtAt(.now, tsFromMs(r.ms))});
        try testing.expectEqualStrings(r.now, w.buffer[0..w.end]);

        w = std.Io.Writer.fixed(&buf);
        try w.print("{f}", .{t.fmtAt(.syslog, tsFromMs(r.ms))});
        try testing.expectEqualStrings(r.syslog, w.buffer[0..w.end]);
    }
}

test "Formatter: the year is not zero-padded" {
    const t = Time.create(testing.io);

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{t.fmtAt(.now, tsFromMs(-62135596800000))}); // 0001-01-01
    try testing.expectEqualStrings("1-01-01 00:00:00.000", w.buffer[0..w.end]);
    try testing.expectEqual(@as(usize, 20), w.end);
}

test "Formatter: fmtAt overrides the clock instead of ignoring its argument" {
    const t = Time.create(testing.io);

    var live_buf: [64]u8 = undefined;
    var live = std.Io.Writer.fixed(&live_buf);
    try live.print("{f}", .{t.fmt(.now)});

    var fixed_buf: [64]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&fixed_buf);
    try fixed.print("{f}", .{t.fmtAt(.now, tsFromMs(0))});

    try testing.expectEqualStrings("1970-01-01 00:00:00.000", fixed.buffer[0..fixed.end]);

    try testing.expect(!std.mem.eql(u8, live.buffer[0..live.end], fixed.buffer[0..fixed.end]));
}

test "nowSeconds is monotonic and in the right ballpark" {
    const a = nowSeconds(testing.io);
    const b = nowSeconds(testing.io);
    try testing.expect(b >= a); // .awake never goes backwards
    try testing.expect(b - a < 5); // and two adjacent calls are not minutes apart
}

test "Formatter: .now renders as YYYY-MM-DD HH:MM:SS.mmm" {
    const t = Time.create(testing.io);
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{t.fmt(.now)});

    try expectShape("dddd-dd-dd dd:dd:dd.ddd", w.buffer[0..w.end]);
    if (show_stamp) std.debug.print("now:    {s}\n", .{w.buffer[0..w.end]});
}

test "Formatter: .syslog renders as 'Mmm DD HH:MM:SS'" {
    const t = Time.create(testing.io);
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{t.fmt(.syslog)});
    const out = w.buffer[0..w.end];

    try expectShape("Ccc dd dd:dd:dd", out);

    var known = false;
    for (MONTH_NAMES) |m| {
        if (std.mem.eql(u8, m, out[0..3])) known = true;
    }
    try testing.expect(known);

    if (show_stamp) std.debug.print("syslog: {s}\n", .{out});
}

// pre-epoch

test "getTimeParts: timestamps before the epoch" {
    const cases = [_]Case{
        .{ .ms = -1, .y = 1969, .mo = 12, .d = 31, .h = 23, .mi = 59, .s = 59, .milli = 999, .note = "one millisecond before the epoch" },
        .{ .ms = -1000, .y = 1969, .mo = 12, .d = 31, .h = 23, .mi = 59, .s = 59, .milli = 0, .note = "one second before the epoch" },
        .{ .ms = -86400000, .y = 1969, .mo = 12, .d = 31, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "exactly one day before the epoch" },
        .{ .ms = -86400001, .y = 1969, .mo = 12, .d = 30, .h = 23, .mi = 59, .s = 59, .milli = 999, .note = "a millisecond into the day before that" },
        .{ .ms = -63158400000, .y = 1968, .mo = 1, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1968-01-01, a leap year before the epoch" },
        .{ .ms = -60480000000, .y = 1968, .mo = 2, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1968-02-01" },
        .{ .ms = -57974400000, .y = 1968, .mo = 3, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1968-03-01, the day after a pre-epoch leap day" },
        .{ .ms = -58060800000, .y = 1968, .mo = 2, .d = 29, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1968-02-29, a pre-epoch leap day" },
        .{ .ms = -2208988800000, .y = 1900, .mo = 1, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1900-01-01" },
        .{ .ms = -2203977600000, .y = 1900, .mo = 2, .d = 28, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1900-02-28" },
        .{ .ms = -2203891200000, .y = 1900, .mo = 3, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1900-03-01 - 1900 is NOT a leap year" },
        .{ .ms = -2208988801000, .y = 1899, .mo = 12, .d = 31, .h = 23, .mi = 59, .s = 59, .milli = 0, .note = "1899-12-31, crossing a century" },
        .{ .ms = -11670998400000, .y = 1600, .mo = 2, .d = 29, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "1600-02-29 - divisible by 400, IS a leap year" },
        .{ .ms = -62135596800000, .y = 1, .mo = 1, .d = 1, .h = 0, .mi = 0, .s = 0, .milli = 0, .note = "0001-01-01, the proleptic Gregorian floor for a u16 year" },
    };
    for (cases) |c| try expectCase(c);
}

test "getTimeParts: consecutive days are continuous across the epoch boundary" {
    var ms: i64 = -10 * std.time.ms_per_day;
    var prev = partsOfMs(ms);
    var n: usize = 0;
    while (n < 20) : (n += 1) {
        ms += std.time.ms_per_day;
        const cur = partsOfMs(ms);
        if (prev.day == 31 and prev.month == 12) {
            try testing.expectEqual(prev.year + 1, cur.year);
            try testing.expectEqual(@as(u4, 1), cur.month);
            try testing.expectEqual(@as(u5, 1), cur.day);
        } else {
            try testing.expectEqual(prev.year, cur.year);
            try testing.expectEqual(prev.month, cur.month);
            try testing.expectEqual(prev.day + 1, cur.day);
        }
        prev = cur;
    }
}
