//! Wall-clock timestamps in the local time zone, without calling date(1).
//!
//! The calendar split (`getTimeParts`) is plain arithmetic on UTC. A `Zone`
//! says how far local time is from UTC at a given instant, read the way
//! date(1) (glibc) does:
//!
//! * `TZ` unset: /etc/localtime; `TZ=""`: UTC; `TZ=Europe/Belgrade` or
//!   `TZ=:Europe/Belgrade`: /usr/share/zoneinfo/Europe/Belgrade; `TZ=/path`:
//!   that file; anything else is taken as a POSIX rule ("CET-1CEST,M3.5.0,
//!   M10.5.0/3"). A zone that cannot be read is UTC, as with glibc.
//! * The file (TZif) is parsed by `std.tz`. It lists the zone's changes up to
//!   some year and ends with a POSIX rule for all later times. "Slim" files
//!   (the zic default since 2020) stop listing early, so the rule is not an
//!   edge case: `Rule` evaluates it.
const std = @import("std");
const assert = std.debug.assert;
const Clock = std.Io.Clock;

const month_names = [12][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

const day_names = [7][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

const TimeParts = struct {
    year: u16,
    month: u4, // 1 = Jan
    day: u5, // 1..31
    weekday: u3, // 0 = Sun
    sub_day: SubDay,
    const SubDay = struct {
        hour: u5,
        minute: u6,
        second: u6,
        millisecond: u16,
    };
};

/// `day_ms` MUST already be reduced to 0..ms_per_day-1. `getTimeParts` does
/// that with a floored division it needs anyway, so the reduction is free
/// here — and taking u32 keeps every division 32-bit rather than 64-bit.
fn getSubDayParts(day_ms: u32) TimeParts.SubDay {
    assert(day_ms < std.time.ms_per_day);
    const hour = day_ms / std.time.ms_per_hour;
    const hour_remainder_ms = day_ms % std.time.ms_per_hour;
    const minute = hour_remainder_ms / std.time.ms_per_min;
    const minute_remainder_ms = hour_remainder_ms % std.time.ms_per_min;
    const second = minute_remainder_ms / std.time.ms_per_s;
    const millisecond = minute_remainder_ms % std.time.ms_per_s;
    assert(hour < 24);
    return .{
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .millisecond = @intCast(millisecond),
    };
}

// Neri-Schneider Gregorian constants.
const days_per_400_years = 146097;
const precision_multiplier = 2939745;

/// Split timestamp into calendar components.
/// Any timestamp whose year lands in 0..65535 is valid.
/// Below year 0 the `@intCast` on the way out will panic.
/// A clock would have to be wrong by two millennia to get there.
fn getTimeParts(timestamp: std.Io.Timestamp) TimeParts {
    const total_ms = timestamp.toMilliseconds();

    // Day / time-of-day split:
    // One floored division yields both the day number and the offset inside
    // that day. @divTrunc rounds toward zero, which puts a pre-epoch
    // timestamp on the wrong side of midnight. Time-of-day (already floored)
    // reports the right clock.
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
    const rd_offset: u32 = 719468 + days_per_400_years * cycle_shift;

    // Shift timestamp days into the algorithmic range:
    // The addition happens in i64. A negative day count is lifted into range
    // before the cast instead of being rejected by it. rd_offset buys ~34,700
    // years below the epoch. @intCast then binds the far end instead of
    // wrapping.
    const shifted_rd: u32 = @intCast(days_since_epoch + rd_offset);

    // Century calculation: extract the 400-year cycle and the century within it.
    const n1 = 4 * shifted_rd + 3;
    const century = n1 / days_per_400_years;
    const days_since_century = (n1 % days_per_400_years) / 4;

    // Year calculation: a fixed-point multiplier finds the year within the century.
    const n2 = 4 * days_since_century + 3;
    const multiplier: u64 = precision_multiplier;
    const pm = multiplier * n2;

    const year_within_century: u32 = @intCast(pm / 4294967296);
    const day_of_year_raw: u32 = @intCast((pm % 4294967296) / precision_multiplier / 4);
    const absolute_year = 100 * century + year_within_century;

    // Month and day calculation using fractional month mapping:
    // 2141 and 197913 are constants that map day-of-year to month lengths
    const month_computation = 2141 * day_of_year_raw + 197913;
    const month_raw = month_computation / 65536;
    const day_raw = (month_computation % 65536) / 2141;

    // The algorithm treats the year as starting on March 1st.
    // We correct for dates in Jan/Feb (day_of_year >= 306) and subtract the cycle shift.
    const is_after_feb = (day_of_year_raw >= 306);
    const year_shifted: i32 = @bitCast(absolute_year -% year_offset);
    const final_year: i32 = year_shifted + @intFromBool(is_after_feb);
    const months_back: u32 = if (is_after_feb) 12 else 0;
    const final_month = month_raw - months_back;
    assert(final_month >= 1);
    assert(final_month <= 12);
    assert(day_raw < 31);

    return .{
        .year = @intCast(final_year),
        .month = @intCast(final_month),
        .day = @intCast(day_raw + 1), //1-based index
        // 1970-01-01 was a Thursday.
        .weekday = @intCast(@mod(days_since_epoch + 4, 7)),
        .sub_day = sub_day,
    };
}

/// Days from 1970-01-01 to `year`-`month`-`day` (proleptic Gregorian), the
/// inverse of the date half of `getTimeParts` (H. Hinnant, days_from_civil).
fn daysFromCivil(year: i32, month: u4, day: u5) i64 {
    assert(month >= 1);
    assert(month <= 12);
    assert(day >= 1);
    // The year counted from March, so that February 29 ends it.
    const year_march: i64 = if (month <= 2) year - 1 else year;
    const era = @divFloor(year_march, 400);
    const year_of_era = year_march - era * 400; // 0..399
    const month_signed: i64 = month;
    const month_from_march = if (month > 2) month_signed - 3 else month_signed + 9;
    const day_of_year = @divFloor(153 * month_from_march + 2, 5) + day - 1; // 0..365
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year; // 0..146096
    assert(day_of_era < days_per_400_years);
    return era * days_per_400_years + day_of_era - 719468;
}

fn isLeap(year: i32) bool {
    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;
    return @mod(year, 4) == 0;
}

fn monthDays(year: i32, month: u4) u5 {
    assert(month >= 1);
    assert(month <= 12);
    const days = [_]u5{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2) {
        if (isLeap(year)) return 29;
    }
    return days[month - 1];
}

const FormatMode = enum {
    /// 2026-10-08 15:40:12.345
    now,
    /// 2026-10-08 15:40:12.345 CEST: `now` with the zone, for log lines.
    log,
    /// Oct 08 15:40:12
    syslog,
    /// Thu Oct  8 15:40:12 CEST 2026, as date(1) prints it with no format
    /// (C locale).
    date,
    /// 15:40 08-10-26, the scripts' `date "+%H:%M %d-%m-%y"` (job start lines).
    job_start,
    /// 261008-15-40-12, the scripts' `date +%y%m%d-%H-%M-%S` (saved log names).
    file_stamp,
};

pub const Time = struct {
    io: std.Io,
    /// UTC unless set (`init`).
    zone: Zone = .{},

    /// Local time of `zone` (see `Zone.load`).
    pub fn init(io: std.Io, zone: Zone) Time {
        return .{ .io = io, .zone = zone };
    }

    /// Entry point for formatting. Use as: .{time.fmt(.now)}
    /// Reads the wall clock at the moment the writer formats it.
    pub fn fmt(time: Time, mode: FormatMode) Formatter {
        return .{ .time = time, .mode = mode, .at = null };
    }

    /// Same as `fmt`, but takes a timestamp instead of reading the clock.
    /// Deterministic, can be used in tests to check formatting.
    pub fn fmtAt(time: Time, mode: FormatMode, at: std.Io.Timestamp) Formatter {
        return .{ .time = time, .mode = mode, .at = at };
    }

    const Formatter = struct {
        time: Time,
        mode: FormatMode,
        /// When null, the formatter reads the clock itself.
        at: ?std.Io.Timestamp = null,

        /// The moment to format, in the local time zone: its parts, and the
        /// zone's offset at that moment.
        const Local = struct { parts: TimeParts, offset: Offset };

        pub fn format(formatter: Formatter, writer: *std.Io.Writer) !void {
            const local = formatter.localTime();
            switch (formatter.mode) {
                .now => {
                    try writer.print("{d}-{:0>2}-{:0>2} {:0>2}:{:0>2}:{:0>2}.{:0>3}", .{
                        local.parts.year,
                        local.parts.month,
                        local.parts.day,
                        local.parts.sub_day.hour,
                        local.parts.sub_day.minute,
                        local.parts.sub_day.second,
                        local.parts.sub_day.millisecond,
                    });
                },
                .log => {
                    try writer.print("{d}-{:0>2}-{:0>2} {:0>2}:{:0>2}:{:0>2}.{:0>3} {s}", .{
                        local.parts.year,
                        local.parts.month,
                        local.parts.day,
                        local.parts.sub_day.hour,
                        local.parts.sub_day.minute,
                        local.parts.sub_day.second,
                        local.parts.sub_day.millisecond,
                        local.offset.name(),
                    });
                },
                .syslog => {
                    try writer.print("{s} {:0>2} {:0>2}:{:0>2}:{:0>2}", .{
                        month_names[local.parts.month - 1], // 0-based index
                        local.parts.day,
                        local.parts.sub_day.hour,
                        local.parts.sub_day.minute,
                        local.parts.sub_day.second,
                    });
                },
                .date => {
                    try writer.print("{s} {s} {d: >2} {:0>2}:{:0>2}:{:0>2} {s} {d}", .{
                        day_names[local.parts.weekday],
                        month_names[local.parts.month - 1],
                        local.parts.day,
                        local.parts.sub_day.hour,
                        local.parts.sub_day.minute,
                        local.parts.sub_day.second,
                        local.offset.name(),
                        local.parts.year,
                    });
                },
                .job_start => {
                    try writer.print("{:0>2}:{:0>2} {:0>2}-{:0>2}-{:0>2}", .{
                        local.parts.sub_day.hour,
                        local.parts.sub_day.minute,
                        local.parts.day,
                        local.parts.month,
                        local.parts.year % 100,
                    });
                },
                .file_stamp => {
                    try writer.print("{:0>2}{:0>2}{:0>2}-{:0>2}-{:0>2}-{:0>2}", .{
                        local.parts.year % 100,
                        local.parts.month,
                        local.parts.day,
                        local.parts.sub_day.hour,
                        local.parts.sub_day.minute,
                        local.parts.sub_day.second,
                    });
                },
            }
        }

        /// `at` (or now) in the local time zone.
        fn localTime(formatter: Formatter) Local {
            const timestamp = formatter.at orelse Clock.now(.real, formatter.time.io);
            const seconds = @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
            const offset = formatter.time.zone.offsetAt(@intCast(seconds));
            const east_seconds: i96 = offset.east;
            const east_ns = east_seconds * std.time.ns_per_s;
            const local: std.Io.Timestamp = .{ .nanoseconds = timestamp.nanoseconds + east_ns };
            return .{ .parts = getTimeParts(local), .offset = offset };
        }
    };
};

// ---------------------------------------------------------------- time zones

/// Local time at one instant: seconds east of UTC and the zone's
/// abbreviation ("CEST"), as date(1) prints it for %Z.
const Offset = struct {
    east: i32,
    name_buffer: [Rule.Name.size_max]u8 = undefined,
    name_length: u8 = 0,

    fn name(offset: *const Offset) []const u8 {
        return offset.name_buffer[0..offset.name_length];
    }

    fn make(east: i32, text: []const u8) Offset {
        // UTC offsets reach -12..+14 hours; a day either way is a bug.
        assert(@abs(east) < std.time.s_per_day);
        var offset: Offset = .{
            .east = east,
            .name_length = @intCast(@min(text.len, Rule.Name.size_max)),
        };
        @memcpy(offset.name_buffer[0..offset.name_length], text[0..offset.name_length]);
        return offset;
    }
};

pub const Zone = struct {
    /// The zone file; null for UTC or a zone given as a POSIX rule.
    tz: ?std.tz.Tz = null,
    /// For times after the last change the file lists (its footer), or the
    /// whole zone when there is no file. Null: a file without a footer,
    /// whose last listed offset then applies.
    rule: ?Rule = .{},

    /// The local zone as date(1) finds it; `tz_env` is the TZ variable.
    /// Never fails: a zone that cannot be read is UTC (as with glibc).
    pub fn load(gpa: std.mem.Allocator, io: std.Io, tz_env: ?[]const u8) Zone {
        const spec = tz_env orelse {
            return fromFile(gpa, io, "/etc/localtime") orelse .{};
        };
        const zone_name = if (std.mem.startsWith(u8, spec, ":")) spec[1..] else spec;
        if (zone_name.len == 0) return .{};
        if (zone_name[0] == '/') return fromFile(gpa, io, zone_name) orelse .{};
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const parts: []const []const u8 = &.{ "/usr/share/zoneinfo", zone_name };
        if (std.mem.print(&path_buffer, "{f}", .{std.Io.Dir.path.fmtJoin(parts)})) |path| {
            if (fromFile(gpa, io, path)) |zone| return zone;
        } else |err| switch (err) {
            error.NoSpaceLeft => {}, // Longer than any path: not a zone name.
        }
        if (Rule.parse(zone_name)) |rule| return .{ .rule = rule };
        return .{};
    }

    /// A TZif file; null when it cannot be read or parsed. A missing file
    /// is normal (TZ may be a rule, /etc/localtime may not exist); other
    /// failures are logged.
    fn fromFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?Zone {
        // Zone files are a few kilobytes; a megabyte is a bound, not a size.
        const size_max: std.Io.Limit = .limited(1 << 20);
        const cwd = std.Io.Dir.cwd();
        const data = cwd.readFileAlloc(io, path, gpa, size_max) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => {
                std.log.warn("time zone file {s}: {t}", .{ path, err });
                return null;
            },
        };
        defer gpa.free(data);
        var reader: std.Io.Reader = .fixed(data);
        const tz = std.tz.Tz.parse(gpa, &reader) catch |err| {
            std.log.warn("time zone file {s}: {t}", .{ path, err });
            return null;
        };
        return .{ .tz = tz, .rule = if (tz.footer) |footer| Rule.parse(footer) else null };
    }

    fn deinit(zone: *Zone) void {
        if (zone.tz) |*tz| tz.deinit();
        zone.* = .{};
    }

    /// Offset at `seconds` (since the epoch, UTC).
    fn offsetAt(zone: Zone, seconds: i64) Offset {
        const tz = zone.tz orelse return zone.rule.?.offsetAt(seconds);
        const transitions = tz.transitions;
        if (transitions.len == 0) {
            if (zone.rule) |rule| return rule.offsetAt(seconds);
            return typeOffset(tz.timetypes[0]);
        }
        if (seconds >= transitions[transitions.len - 1].ts) {
            if (zone.rule) |rule| return rule.offsetAt(seconds);
        }
        // RFC 8536: before the first transition, the first time type.
        if (seconds < transitions[0].ts) return typeOffset(tz.timetypes[0]);
        // The last transition at or before `seconds`: a binary search, which
        // halves the range each round.
        var low: usize = 0;
        var high: usize = transitions.len;
        while (high - low > 1) {
            const middle = low + (high - low) / 2;
            if (transitions[middle].ts <= seconds) low = middle else high = middle;
        }
        assert(transitions[low].ts <= seconds);
        return typeOffset(transitions[low].timetype.*);
    }

    fn typeOffset(timetype: std.tz.Timetype) Offset {
        return .make(timetype.offset, timetype.name());
    }
};

/// A POSIX TZ rule, e.g. "CET-1CEST,M3.5.0,M10.5.0/3": standard time one
/// hour east of UTC (POSIX counts west, hence "-1"), summer time from the
/// last Sunday of March 02:00 to the last Sunday of October 03:00 local.
/// Covers POSIX plus the RFC 8536 extensions (hours -167..167 for change
/// times).
const Rule = struct {
    std_name: Name = .of("UTC"),
    /// Seconds east of UTC.
    std_east: i32 = 0,
    dst: ?Dst = null,

    const Name = struct {
        const size_max = 16;
        buffer: [size_max]u8 = undefined,
        length: u8 = 0,

        fn slice(name: *const Name) []const u8 {
            return name.buffer[0..name.length];
        }

        fn of(text: []const u8) Name {
            assert(text.len <= size_max);
            var name: Name = .{ .length = @intCast(text.len) };
            @memcpy(name.buffer[0..text.len], text);
            return name;
        }
    };

    const Dst = struct {
        name: Name,
        east: i32,
        start: Change,
        end: Change,
    };

    /// When summer time starts or ends: a day, and seconds after that
    /// day's local midnight (standard time for the start, summer time for
    /// the end).
    const Change = struct {
        date: Date,
        time: i32 = 2 * std.time.s_per_hour,
    };

    const Date = union(enum) {
        /// Jn: day 1..365, February 29 never counted.
        julian1: u16,
        /// n: day 0..365, February 29 counted in leap years.
        julian0: u16,
        /// Mm.w.d: weekday d (0 = Sunday) of week w (5 = last) of month m.
        mwd: MonthWeekDay,
    };

    const MonthWeekDay = struct { month: u4, week: u3, weekday: u3 };

    fn parse(text: []const u8) ?Rule {
        var parser: Parser = .{ .text = text };
        const std_name = parser.name() orelse return null;
        const std_offset = parser.hms(24) orelse return null;
        var rule: Rule = .{ .std_name = std_name, .std_east = -std_offset };
        if (parser.done()) return rule;

        const dst_name = parser.name() orelse return null;
        var dst_east = rule.std_east + std.time.s_per_hour;
        if (parser.peek()) |character| {
            if (startsOffset(character)) dst_east = -(parser.hms(24) orelse return null);
        }
        // No dates: the POSIX default, as glibc (US rules since 2007).
        var start: Change = .{ .date = .{ .mwd = .{ .month = 3, .week = 2, .weekday = 0 } } };
        var end: Change = .{ .date = .{ .mwd = .{ .month = 11, .week = 1, .weekday = 0 } } };
        if (!parser.done()) {
            if (!parser.eat(',')) return null;
            start = parser.change() orelse return null;
            if (!parser.eat(',')) return null;
            end = parser.change() orelse return null;
        }
        if (!parser.done()) return null;
        rule.dst = .{ .name = dst_name, .east = dst_east, .start = start, .end = end };
        return rule;
    }

    fn startsOffset(character: u8) bool {
        if (character == '+') return true;
        if (character == '-') return true;
        return std.ascii.isDigit(character);
    }

    fn offsetAt(rule: Rule, seconds: i64) Offset {
        const dst = rule.dst orelse return .make(rule.std_east, rule.std_name.slice());
        // The year in local standard time; the change times of that year.
        const local_seconds: i96 = seconds + rule.std_east;
        const local_ns = local_seconds * std.time.ns_per_s;
        const year: i32 = getTimeParts(.fromNanoseconds(local_ns)).year;
        const start = dayOf(year, dst.start.date) * std.time.s_per_day +
            dst.start.time - rule.std_east;
        const end = dayOf(year, dst.end.date) * std.time.s_per_day + dst.end.time - dst.east;
        if (inSummer(seconds, start, end)) return .make(dst.east, dst.name.slice());
        return .make(rule.std_east, rule.std_name.slice());
    }

    /// Whether `seconds` falls in summer time that starts at `start` and
    /// ends at `end` of the same year. In the southern hemisphere summer
    /// time spans the new year (`end` before `start`).
    fn inSummer(seconds: i64, start: i64, end: i64) bool {
        if (start < end) {
            if (seconds < start) return false;
            return seconds < end;
        } else {
            if (seconds >= end) return seconds >= start;
            return true;
        }
    }

    /// Days since the epoch of `date` in `year`.
    fn dayOf(year: i32, date: Date) i64 {
        const january_1 = daysFromCivil(year, 1, 1);
        switch (date) {
            .julian1 => |number| {
                // February 29 is never counted: from March on, a leap year is a day ahead.
                const skip_leap_day = isLeap(year) and number >= 60;
                return january_1 + number - 1 + @intFromBool(skip_leap_day);
            },
            .julian0 => |number| return january_1 + number,
            .mwd => |mwd| {
                const first = daysFromCivil(year, mwd.month, 1);
                const first_weekday = @mod(first + 4, 7);
                const weekday: i64 = mwd.weekday;
                const week: i64 = mwd.week;
                const weekday_first = first + @mod(weekday - first_weekday, 7);
                var day = weekday_first + 7 * (week - 1);
                // Week 5 is the last one: at most one week past the month's end.
                if (day >= first + monthDays(year, mwd.month)) day -= 7;
                assert(day >= first);
                assert(day < first + monthDays(year, mwd.month));
                return day;
            },
        }
    }

    const Parser = struct {
        text: []const u8,
        index: usize = 0,

        fn peek(parser: Parser) ?u8 {
            if (parser.index < parser.text.len) return parser.text[parser.index];
            return null;
        }

        fn done(parser: Parser) bool {
            assert(parser.index <= parser.text.len);
            return parser.index == parser.text.len;
        }

        fn eat(parser: *Parser, character: u8) bool {
            if (parser.peek() != character) return false;
            parser.index += 1;
            return true;
        }

        /// "CET", or quoted "<+0530>"; at least 3 characters.
        fn name(parser: *Parser) ?Name {
            const start = parser.index;
            var text: []const u8 = undefined;
            if (parser.eat('<')) {
                while (parser.peek()) |character| : (parser.index += 1) {
                    if (character == '>') break;
                }
                text = parser.text[start + 1 .. parser.index];
                if (!parser.eat('>')) return null;
            } else {
                while (parser.peek()) |character| : (parser.index += 1) {
                    if (!std.ascii.isAlphabetic(character)) break;
                }
                text = parser.text[start..parser.index];
            }
            if (text.len < 3) return null;
            if (text.len > Name.size_max) return null;
            return .of(text);
        }

        fn number(parser: *Parser, value_max: u32) ?u32 {
            const start = parser.index;
            var value: u32 = 0;
            while (parser.peek()) |character| : (parser.index += 1) {
                if (!std.ascii.isDigit(character)) break;
                value = value * 10 + (character - '0');
                if (value > value_max) return null;
            }
            if (parser.index > start) return value;
            return null;
        }

        /// [+-]hh[:mm[:ss]] in seconds (sign as written).
        fn hms(parser: *Parser, hours_max: u32) ?i32 {
            const negative = parser.eat('-');
            if (!negative) _ = parser.eat('+');
            const hours = parser.number(hours_max) orelse return null;
            var value: i32 = @intCast(hours * std.time.s_per_hour);
            if (parser.eat(':')) {
                const minutes = parser.number(59) orelse return null;
                value += @intCast(minutes * std.time.s_per_min);
                if (parser.eat(':')) value += @intCast(parser.number(59) orelse return null);
            }
            if (negative) return -value;
            return value;
        }

        fn change(parser: *Parser) ?Change {
            var result: Change = .{ .date = undefined };
            if (parser.eat('J')) {
                const day = parser.number(365) orelse return null;
                if (day == 0) return null;
                result.date = .{ .julian1 = @intCast(day) };
            } else if (parser.eat('M')) {
                result.date = .{ .mwd = parser.monthWeekDay() orelse return null };
            } else {
                result.date = .{ .julian0 = @intCast(parser.number(365) orelse return null) };
            }
            if (parser.eat('/')) result.time = parser.hms(167) orelse return null;
            return result;
        }

        /// m.w.d after the "M".
        fn monthWeekDay(parser: *Parser) ?MonthWeekDay {
            const month = parser.number(12) orelse return null;
            if (month == 0) return null;
            if (!parser.eat('.')) return null;
            const week = parser.number(5) orelse return null;
            if (week == 0) return null;
            if (!parser.eat('.')) return null;
            const weekday = parser.number(6) orelse return null;
            return .{
                .month = @intCast(month),
                .week = @intCast(week),
                .weekday = @intCast(weekday),
            };
        }
    };
};

/// Selected clock for tracking packet timestamps
const local_clock: Clock = .awake;
/// Monotonic milliseconds, excludes OS suspended time.
/// Used for correct interval tracking
pub fn nowMs(io: std.Io) i64 {
    return Clock.Timestamp.now(io, local_clock).raw.toMilliseconds();
}

/// Constructs a `Timeout` based upon passed duration in milliseconds
pub fn timer(duration: i64) std.Io.Timeout {
    return .{
        .deadline = .{
            .raw = .{ .nanoseconds = @intCast(duration * std.time.ns_per_ms) },
            .clock = local_clock,
        },
    };
}

// ---------------------------------------------------------------- tests

// Pre-epoch timestamps are covered. One floored division now feeds both the
// day number and the time of day, and the rd_offset shift happens in i64, so
// dates below 1970 are ordinary inputs.

/// Use only in testing.
const testing = std.testing;

/// Use only in testing.
const show_stamp = false;

/// Use only in testing. Build a `Timestamp` from milliseconds since the Unix epoch. No `Io`.
fn tsFromMs(ms: i64) std.Io.Timestamp {
    const ms_wide: i96 = ms;
    return .fromNanoseconds(ms_wide * std.time.ns_per_ms);
}

/// Use only in testing.
fn partsOfMs(ms: i64) TimeParts {
    return getTimeParts(tsFromMs(ms));
}

/// Use only in testing.
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

/// Use only in testing.
fn expectCase(c: Case) !void {
    const p = partsOfMs(c.ms);
    const sub_day = p.sub_day;
    const got: [7]u64 = .{
        p.year,
        p.month,
        p.day,
        sub_day.hour,
        sub_day.minute,
        sub_day.second,
        sub_day.millisecond,
    };
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

/// Use only in testing.
fn expectShape(template: []const u8, out: []const u8) !void {
    try testing.expectEqual(template.len, out.len);
    for (template, out) |t, c| switch (t) {
        'd' => try testing.expect(std.ascii.isDigit(c)),
        'C' => try testing.expect(std.ascii.isUpper(c)),
        'c' => try testing.expect(std.ascii.isLower(c)),
        else => try testing.expectEqual(t, c),
    };
}

// ------------------------------------------------------------------------ Rule

/// Use only in testing.
fn offsetName(o: Offset) []const u8 {
    return o.name_buffer[0..o.name_length];
}

/// Use only in testing.
const Expected = struct { at: i64, before: i32, after: i32, name: []const u8 };

/// Use only in testing. The offset changes exactly at `c.at`.
fn expectChange(z: Zone, c: Expected) !void {
    try testing.expectEqual(c.before, z.offsetAt(c.at - 1).east);
    const o = z.offsetAt(c.at);
    try testing.expectEqual(c.after, o.east);
    try testing.expectEqualStrings(c.name, offsetName(o));
}

// ---------------------------------------------------------------- getTimeParts

test "getTimeParts: known timestamps across leap rules and boundaries" {
    const cases = [_]Case{
        .{
            .ms = 0,
            .y = 1970,
            .mo = 1,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "the epoch itself",
        },
        .{
            .ms = 1,
            .y = 1970,
            .mo = 1,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 1,
            .note = "one millisecond in",
        },
        .{
            .ms = 86399999,
            .y = 1970,
            .mo = 1,
            .d = 1,
            .h = 23,
            .mi = 59,
            .s = 59,
            .milli = 999,
            .note = "last instant of day one",
        },
        .{
            .ms = 86400000,
            .y = 1970,
            .mo = 1,
            .d = 2,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "first instant of day two",
        },
        .{
            .ms = 5054400000,
            .y = 1970,
            .mo = 2,
            .d = 28,
            .h = 12,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1970 Feb 28",
        },
        .{
            .ms = 5097600000,
            .y = 1970,
            .mo = 3,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1970 Mar 1 - the algorithm's year boundary",
        },
        .{
            .ms = 31535999999,
            .y = 1970,
            .mo = 12,
            .d = 31,
            .h = 23,
            .mi = 59,
            .s = 59,
            .milli = 999,
            .note = "last instant of 1970",
        },
        .{
            .ms = 31536000000,
            .y = 1971,
            .mo = 1,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "first instant of 1971",
        },
        .{
            .ms = 36547200000,
            .y = 1971,
            .mo = 2,
            .d = 28,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "non-leap Feb 28",
        },
        .{
            .ms = 36633600000,
            .y = 1971,
            .mo = 3,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "non-leap Mar 1 - no Feb 29 to skip",
        },
        .{
            .ms = 68083200000,
            .y = 1972,
            .mo = 2,
            .d = 28,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "first leap year after the epoch, Feb 28",
        },
        .{
            .ms = 68214896789,
            .y = 1972,
            .mo = 2,
            .d = 29,
            .h = 12,
            .mi = 34,
            .s = 56,
            .milli = 789,
            .note = "first leap day after the epoch",
        },
        .{
            .ms = 68256000000,
            .y = 1972,
            .mo = 3,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "day after the first leap day",
        },
        .{
            .ms = 94694399999,
            .y = 1972,
            .mo = 12,
            .d = 31,
            .h = 23,
            .mi = 59,
            .s = 59,
            .milli = 999,
            .note = "end of a leap year",
        },
        .{
            .ms = 946684799999,
            .y = 1999,
            .mo = 12,
            .d = 31,
            .h = 23,
            .mi = 59,
            .s = 59,
            .milli = 999,
            .note = "Y2K eve",
        },
        .{
            .ms = 946684800000,
            .y = 2000,
            .mo = 1,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "Y2K",
        },
        .{
            .ms = 951696000000,
            .y = 2000,
            .mo = 2,
            .d = 28,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "2000 Feb 28",
        },
        .{
            .ms = 951825600000,
            .y = 2000,
            .mo = 2,
            .d = 29,
            .h = 12,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "2000 Feb 29 - divisible by 400, is a leap year",
        },
        .{
            .ms = 951868800000,
            .y = 2000,
            .mo = 3,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "2000 Mar 1",
        },
        .{
            .ms = 1709251199500,
            .y = 2024,
            .mo = 2,
            .d = 29,
            .h = 23,
            .mi = 59,
            .s = 59,
            .milli = 500,
            .note = "2024 leap day, last half second",
        },
        .{
            .ms = 2147483647000,
            .y = 2038,
            .mo = 1,
            .d = 19,
            .h = 3,
            .mi = 14,
            .s = 7,
            .milli = 0,
            .note = "signed 32-bit second rollover",
        },
        .{
            .ms = 2147483648000,
            .y = 2038,
            .mo = 1,
            .d = 19,
            .h = 3,
            .mi = 14,
            .s = 8,
            .milli = 0,
            .note = "one second past the rollover",
        },
        .{
            .ms = 4102444799999,
            .y = 2099,
            .mo = 12,
            .d = 31,
            .h = 23,
            .mi = 59,
            .s = 59,
            .milli = 999,
            .note = "end of the 21st century",
        },
        .{
            .ms = 4107456000000,
            .y = 2100,
            .mo = 2,
            .d = 28,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "2100 Feb 28",
        },
        .{
            .ms = 4107542400000,
            .y = 2100,
            .mo = 3,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "2100 Mar 1 - divisible by 100, not a leap year",
        },
        .{
            .ms = 13574563200000,
            .y = 2400,
            .mo = 2,
            .d = 29,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "2400 Feb 29 - divisible by 400 again",
        },
        .{
            .ms = 978307200000,
            .y = 2001,
            .mo = 1,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "start of a century-ish year",
        },
        .{
            .ms = 1465979445123,
            .y = 2016,
            .mo = 6,
            .d = 15,
            .h = 8,
            .mi = 30,
            .s = 45,
            .milli = 123,
            .note = "an ordinary instant",
        },
        .{
            .ms = 253402300799999,
            .y = 9999,
            .mo = 12,
            .d = 31,
            .h = 23,
            .mi = 59,
            .s = 59,
            .milli = 999,
            .note = "the last four-digit year",
        },
    };
    for (cases) |c| try expectCase(c);
}

test "getTimeParts: every month of a non-leap year starts on the right day" {
    // 1971 is the first full non-leap year after the epoch. Walking the first of
    // each month checks the 2141/197913 month mapping in both halves of the
    // algorithm's March-to-February year.
    const firsts = [_]Case{
        .{
            .ms = 31536000000,
            .y = 1971,
            .mo = 1,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1971-01-01",
        },
        .{
            .ms = 34214400000,
            .y = 1971,
            .mo = 2,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1971-02-01",
        },
        .{
            .ms = 36633600000,
            .y = 1971,
            .mo = 3,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1971-03-01",
        },
        .{
            .ms = 39312000000,
            .y = 1971,
            .mo = 4,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1971-04-01",
        },
        .{
            .ms = 41904000000,
            .y = 1971,
            .mo = 5,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1971-05-01",
        },
        .{
            .ms = 44582400000,
            .y = 1971,
            .mo = 6,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1971-06-01",
        },
        .{
            .ms = 47174400000,
            .y = 1971,
            .mo = 7,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1971-07-01",
        },
        .{
            .ms = 49852800000,
            .y = 1971,
            .mo = 8,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1971-08-01",
        },
        .{
            .ms = 52531200000,
            .y = 1971,
            .mo = 9,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1971-09-01",
        },
        .{
            .ms = 55123200000,
            .y = 1971,
            .mo = 10,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1971-10-01",
        },
        .{
            .ms = 57801600000,
            .y = 1971,
            .mo = 11,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1971-11-01",
        },
        .{
            .ms = 60393600000,
            .y = 1971,
            .mo = 12,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1971-12-01",
        },
    };
    for (firsts) |c| try expectCase(c);
}

test "getTimeParts: every month of a leap year starts on the right day" {
    const firsts = [_]Case{
        .{
            .ms = 63072000000,
            .y = 1972,
            .mo = 1,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1972-01-01",
        },
        .{
            .ms = 65750400000,
            .y = 1972,
            .mo = 2,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1972-02-01",
        },
        .{
            .ms = 68256000000,
            .y = 1972,
            .mo = 3,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1972-03-01",
        },
        .{
            .ms = 70934400000,
            .y = 1972,
            .mo = 4,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1972-04-01",
        },
        .{
            .ms = 73526400000,
            .y = 1972,
            .mo = 5,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1972-05-01",
        },
        .{
            .ms = 76204800000,
            .y = 1972,
            .mo = 6,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1972-06-01",
        },
        .{
            .ms = 78796800000,
            .y = 1972,
            .mo = 7,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1972-07-01",
        },
        .{
            .ms = 81475200000,
            .y = 1972,
            .mo = 8,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1972-08-01",
        },
        .{
            .ms = 84153600000,
            .y = 1972,
            .mo = 9,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1972-09-01",
        },
        .{
            .ms = 86745600000,
            .y = 1972,
            .mo = 10,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1972-10-01",
        },
        .{
            .ms = 89424000000,
            .y = 1972,
            .mo = 11,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1972-11-01",
        },
        .{
            .ms = 92016000000,
            .y = 1972,
            .mo = 12,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1972-12-01",
        },
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
    const tod: i64 = 13 * std.time.ms_per_hour + 37 * std.time.ms_per_min +
        42 * std.time.ms_per_s + 123;
    for ([_]i64{ 0, 946684800000, 4107456000000 }) |day_start| {
        const p = partsOfMs(day_start + tod);
        try testing.expectEqual(@as(u5, 13), p.sub_day.hour);
        try testing.expectEqual(@as(u6, 37), p.sub_day.minute);
        try testing.expectEqual(@as(u6, 42), p.sub_day.second);
        try testing.expectEqual(@as(u16, 123), p.sub_day.millisecond);
    }
}

// -------------------------------------------------------------- getSubDayParts

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
        try testing.expectEqual(r.mi, p.minute);
        try testing.expectEqual(r.s, p.second);
        try testing.expectEqual(r.milli, p.millisecond);
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
    try testing.expectEqual(@as(u16, 999), a.sub_day.millisecond);

    const b = partsOfMs(-std.time.ms_per_day);
    try testing.expectEqual(@as(u16, 1969), b.year);
    try testing.expectEqual(@as(u5, 31), b.day);
    try testing.expectEqual(@as(u5, 0), b.sub_day.hour);
    try testing.expectEqual(@as(u16, 0), b.sub_day.millisecond);
}

test "getSubDayParts: every hour and minute of a day round-trips" {
    var h: u5 = 0;
    while (h < 24) : (h += 1) {
        var mi: u6 = 0;
        while (mi < 60) : (mi += 1) {
            const hours: u32 = h;
            const minutes: u32 = mi;
            const ms = hours * std.time.ms_per_hour + minutes * std.time.ms_per_min + 30_500;
            const p = getSubDayParts(ms);
            try testing.expectEqual(h, p.hour);
            try testing.expectEqual(mi, p.minute);
            try testing.expectEqual(@as(u6, 30), p.second);
            try testing.expectEqual(@as(u16, 500), p.millisecond);
        }
    }
}

// ----------------------------------------------------------------- month names

test "month_names: twelve entries, indexed by month - 1" {
    try testing.expectEqual(@as(usize, 12), month_names.len);
    for (month_names) |m| try testing.expectEqual(@as(usize, 3), m.len);

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
        try testing.expectEqualStrings(f.name, month_names[p.month - 1]);
    }
}

test "Formatter: exact output at known timestamps" {
    const t: Time = .{ .io = testing.io };

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
    const t: Time = .{ .io = testing.io };

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{t.fmtAt(.now, tsFromMs(-62135596800000))}); // 0001-01-01
    try testing.expectEqualStrings("1-01-01 00:00:00.000", w.buffer[0..w.end]);
    try testing.expectEqual(@as(usize, 20), w.end);
}

test "Formatter: fmtAt overrides the clock instead of ignoring its argument" {
    const t: Time = .{ .io = testing.io };

    var live_buf: [64]u8 = undefined;
    var live = std.Io.Writer.fixed(&live_buf);
    try live.print("{f}", .{t.fmt(.now)});

    var fixed_buf: [64]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&fixed_buf);
    try fixed.print("{f}", .{t.fmtAt(.now, tsFromMs(0))});

    try testing.expectEqualStrings("1970-01-01 00:00:00.000", fixed.buffer[0..fixed.end]);

    try testing.expect(!std.mem.eql(u8, live.buffer[0..live.end], fixed.buffer[0..fixed.end]));
}

test "Formatter: .now renders as YYYY-MM-DD HH:MM:SS.mmm" {
    const t: Time = .{ .io = testing.io };
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{t.fmt(.now)});

    try expectShape("dddd-dd-dd dd:dd:dd.ddd", w.buffer[0..w.end]);
    if (show_stamp) std.debug.print("now:    {s}\n", .{w.buffer[0..w.end]});
}

test "Formatter: .syslog renders as 'Mmm DD HH:MM:SS'" {
    const t: Time = .{ .io = testing.io };
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{t.fmt(.syslog)});
    const out = w.buffer[0..w.end];

    try expectShape("Ccc dd dd:dd:dd", out);

    var known = false;
    for (month_names) |m| {
        if (std.mem.eql(u8, m, out[0..3])) known = true;
    }
    try testing.expect(known);

    if (show_stamp) std.debug.print("syslog: {s}\n", .{out});
}

// ------------------------------------------------------------------- pre-epoch

test "getTimeParts: timestamps before the epoch" {
    const cases = [_]Case{
        .{
            .ms = -1,
            .y = 1969,
            .mo = 12,
            .d = 31,
            .h = 23,
            .mi = 59,
            .s = 59,
            .milli = 999,
            .note = "one millisecond before the epoch",
        },
        .{
            .ms = -1000,
            .y = 1969,
            .mo = 12,
            .d = 31,
            .h = 23,
            .mi = 59,
            .s = 59,
            .milli = 0,
            .note = "one second before the epoch",
        },
        .{
            .ms = -86400000,
            .y = 1969,
            .mo = 12,
            .d = 31,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "exactly one day before the epoch",
        },
        .{
            .ms = -86400001,
            .y = 1969,
            .mo = 12,
            .d = 30,
            .h = 23,
            .mi = 59,
            .s = 59,
            .milli = 999,
            .note = "a millisecond into the day before that",
        },
        .{
            .ms = -63158400000,
            .y = 1968,
            .mo = 1,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1968-01-01, a leap year before the epoch",
        },
        .{
            .ms = -60480000000,
            .y = 1968,
            .mo = 2,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1968-02-01",
        },
        .{
            .ms = -57974400000,
            .y = 1968,
            .mo = 3,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1968-03-01, the day after a pre-epoch leap day",
        },
        .{
            .ms = -58060800000,
            .y = 1968,
            .mo = 2,
            .d = 29,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1968-02-29, a pre-epoch leap day",
        },
        .{
            .ms = -2208988800000,
            .y = 1900,
            .mo = 1,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1900-01-01",
        },
        .{
            .ms = -2203977600000,
            .y = 1900,
            .mo = 2,
            .d = 28,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1900-02-28",
        },
        .{
            .ms = -2203891200000,
            .y = 1900,
            .mo = 3,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1900-03-01 - 1900 is NOT a leap year",
        },
        .{
            .ms = -2208988801000,
            .y = 1899,
            .mo = 12,
            .d = 31,
            .h = 23,
            .mi = 59,
            .s = 59,
            .milli = 0,
            .note = "1899-12-31, crossing a century",
        },
        .{
            .ms = -11670998400000,
            .y = 1600,
            .mo = 2,
            .d = 29,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "1600-02-29 - divisible by 400, IS a leap year",
        },
        .{
            .ms = -62135596800000,
            .y = 1,
            .mo = 1,
            .d = 1,
            .h = 0,
            .mi = 0,
            .s = 0,
            .milli = 0,
            .note = "0001-01-01, the proleptic Gregorian floor for a u16 year",
        },
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

// ------------------------------------------------------ weekday, daysFromCivil

test "getTimeParts: weekday" {
    try testing.expectEqual(@as(u3, 4), partsOfMs(0).weekday); // Thu 1970-01-01
    try testing.expectEqual(@as(u3, 3), partsOfMs(-1).weekday); // Wed 1969-12-31
    try testing.expectEqual(@as(u3, 6), partsOfMs(946684800000).weekday); // Sat 2000-01-01
    try testing.expectEqual(@as(u3, 4), partsOfMs(1791417600000).weekday); // Thu 2026-10-08
}

test "daysFromCivil is the inverse of getTimeParts" {
    var day: i64 = -700_000; // year 53 .. 9909
    while (day < 2_900_000) : (day += 97) {
        const p = getTimeParts(.fromNanoseconds(@as(i96, day) * std.time.ns_per_day));
        try testing.expectEqual(day, daysFromCivil(p.year, p.month, p.day));
    }
}

test "Rule: 2026 changes of zones on both hemispheres and odd rules" {
    // Expected values from Python's zoneinfo (tzdata 2025).
    const zones = [_]struct { rule: []const u8, changes: [2]Expected }{
        .{ .rule = "CET-1CEST,M3.5.0,M10.5.0/3", .changes = .{
            .{ .at = 1774746000, .before = 3600, .after = 7200, .name = "CEST" },
            .{ .at = 1792890000, .before = 7200, .after = 3600, .name = "CET" },
        } },
        .{ .rule = "EST5EDT,M3.2.0,M11.1.0", .changes = .{
            .{ .at = 1772953200, .before = -18000, .after = -14400, .name = "EDT" },
            .{ .at = 1793512800, .before = -14400, .after = -18000, .name = "EST" },
        } },
        // Southern: summer time spans the new year.
        .{ .rule = "AEST-10AEDT,M10.1.0,M4.1.0/3", .changes = .{
            .{ .at = 1775318400, .before = 39600, .after = 36000, .name = "AEST" },
            .{ .at = 1791043200, .before = 36000, .after = 39600, .name = "AEDT" },
        } },
        // Negative change time, quoted names.
        .{ .rule = "<-02>2<-01>,M3.5.0/-1,M10.5.0/0", .changes = .{
            .{ .at = 1774746000, .before = -7200, .after = -3600, .name = "-01" },
            .{ .at = 1792890000, .before = -3600, .after = -7200, .name = "-02" },
        } },
        // Minutes in offsets and change times.
        .{ .rule = "<+1245>-12:45<+1345>,M9.5.0/2:45,M4.1.0/3:45", .changes = .{
            .{ .at = 1775311200, .before = 49500, .after = 45900, .name = "+1245" },
            .{ .at = 1790431200, .before = 45900, .after = 49500, .name = "+1345" },
        } },
    };
    for (zones) |zc| {
        const z: Zone = .{ .rule = Rule.parse(zc.rule) orelse return error.TestUnexpectedResult };
        for (zc.changes) |c| expectChange(z, c) catch |err| {
            std.debug.print("rule {s}, change at {d}\n", .{ zc.rule, c.at });
            return err;
        };
    }
}

test "Rule: parse" {
    const kolkata = Rule.parse("IST-5:30").?;
    try testing.expectEqual(@as(i32, 19800), kolkata.std_east);
    try testing.expect(kolkata.dst == null);
    try testing.expectEqual(@as(i32, 0), Rule.parse("UTC0").?.std_east);
    try testing.expectEqual(@as(i32, -10800), Rule.parse("<-03>3").?.std_east);
    // Summer time offset defaults to one hour more; dates to the US rule.
    const est = Rule.parse("EST5EDT").?;
    try testing.expectEqual(@as(i32, -14400), est.dst.?.east);
    try testing.expectEqual(@as(u4, 3), est.dst.?.start.date.mwd.month);
    const j = Rule.parse("AAA3BBB2,J60/0,300/25").?;
    try testing.expectEqual(@as(i32, -7200), j.dst.?.east);
    try testing.expectEqual(@as(u16, 60), j.dst.?.start.date.julian1);
    try testing.expectEqual(@as(u16, 300), j.dst.?.end.date.julian0);
    try testing.expectEqual(@as(i32, 25 * 3600), j.dst.?.end.time);
    const bad_rules = [_][]const u8{
        "",
        "C",
        "CE-1",
        "CET",
        "CET-1CEST,M13.1.0,M10.5.0",
        "CET-1CEST,M3.5.0",
        "CET-1CEST,J0,J5",
        "CET-1 ",
        "<CET-1",
    };
    for (bad_rules) |bad| {
        testing.expect(Rule.parse(bad) == null) catch |err| {
            std.debug.print("accepted \"{s}\"\n", .{bad});
            return err;
        };
    }
}

test "Rule: Jn skips February 29, n counts it" {
    // J60 is March 1 in every year; day 59 (from 0) is Feb 29 in a leap year.
    try testing.expectEqual(daysFromCivil(2024, 3, 1), Rule.dayOf(2024, .{ .julian1 = 60 }));
    try testing.expectEqual(daysFromCivil(2025, 3, 1), Rule.dayOf(2025, .{ .julian1 = 60 }));
    try testing.expectEqual(daysFromCivil(2024, 2, 29), Rule.dayOf(2024, .{ .julian0 = 59 }));
    // Week 5 is the last such weekday, also when the month has only four.
    const last_sunday: Rule.Date = .{ .mwd = .{ .month = 2, .week = 5, .weekday = 0 } };
    try testing.expectEqual(daysFromCivil(2026, 2, 22), Rule.dayOf(2026, last_sunday));
}

// ------------------------------------------------------------------ Zone files

// Zone files of the system, if any: their listed changes (written by zic)
// against our evaluation of their own footer rule, every 30 minutes over
// the years both cover.
test "Zone: the footer rule agrees with the changes the file lists" {
    const io = testing.io;
    const names = [_][]const u8{
        "Europe/Belgrade", "America/New_York", "Australia/Sydney", "America/Nuuk",
        "Pacific/Chatham", "America/Santiago", "Pacific/Auckland", "Asia/Kolkata",
        "America/Havana",  "Asia/Tehran",      "Europe/Dublin",    "Africa/Cairo",
    };
    var checked: usize = 0;
    for (names) |n| {
        var buf: [128]u8 = undefined;
        const path = try std.mem.print(&buf, "/usr/share/zoneinfo/{s}", .{n});
        var z = Zone.fromFile(testing.allocator, io, path) orelse continue;
        defer z.deinit();
        const rule = z.rule orelse continue;
        const tr = z.tz.?.transitions;
        if (tr.len == 0) continue;
        // From the year after the last change the rule did not make yet
        // (tzdata changes of the past) up to the file's last listed change.
        var t: i64 = @max(tr[tr.len - 1].ts - 10 * 365 * std.time.s_per_day, 1767225600); // 2026
        while (t < tr[tr.len - 1].ts) : (t += 1800) {
            const want = z.offsetAt(t);
            const got = rule.offsetAt(t);
            if (want.east != got.east or !std.mem.eql(u8, offsetName(want), offsetName(got))) {
                std.debug.print("{s} at {d}: file {d} {s}, rule {d} {s}\n", .{
                    n,
                    t,
                    want.east,
                    offsetName(want),
                    got.east,
                    offsetName(got),
                });
                return error.TestUnexpectedResult;
            }
        }
        checked += 1;
    }
    if (checked == 0) return error.SkipZigTest;
}

test "Zone.load: TZ forms, and UTC for what cannot be read" {
    const io = testing.io;
    const gpa = testing.allocator;
    var z = Zone.load(gpa, io, "");
    try testing.expectEqualStrings("UTC", offsetName(z.offsetAt(0)));
    z = Zone.load(gpa, io, "No/Such_Zone");
    try testing.expectEqual(@as(i32, 0), z.offsetAt(0).east);
    z = Zone.load(gpa, io, "IST-5:30"); // not a file: a rule
    try testing.expectEqual(@as(i32, 19800), z.offsetAt(0).east);
    var f = Zone.load(gpa, io, ":Europe/Belgrade");
    defer f.deinit();
    if (f.tz == null) return error.SkipZigTest;
    try testing.expectEqual(@as(i32, 7200), f.offsetAt(1774746000).east);
}

test "Formatter: date(1) formats in a zone" {
    const z: Zone = .{ .rule = Rule.parse("CET-1CEST,M3.5.0,M10.5.0/3").? };
    const t = Time.init(testing.io, z);
    const rows = [_]struct { s: i64, mode: FormatMode, out: []const u8 }{
        .{ .s = 1774746000 - 1, .mode = .date, .out = "Sun Mar 29 01:59:59 CET 2026" },
        .{ .s = 1774746000, .mode = .date, .out = "Sun Mar 29 03:00:00 CEST 2026" },
        .{ .s = 1791475248, .mode = .date, .out = "Thu Oct  8 18:00:48 CEST 2026" },
        .{ .s = 1791475248, .mode = .job_start, .out = "18:00 08-10-26" },
        .{ .s = 1791475248, .mode = .file_stamp, .out = "261008-18-00-48" },
        .{ .s = 1791475248, .mode = .now, .out = "2026-10-08 18:00:48.000" },
        .{ .s = 1791475248, .mode = .log, .out = "2026-10-08 18:00:48.000 CEST" },
        .{ .s = 1792890000, .mode = .log, .out = "2026-10-25 02:00:00.000 CET" },
        .{ .s = 1792890000, .mode = .syslog, .out = "Oct 25 02:00:00" },
    };
    for (rows) |r| {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try w.print("{f}", .{t.fmtAt(r.mode, .fromNanoseconds(@as(i96, r.s) * std.time.ns_per_s))});
        try testing.expectEqualStrings(r.out, w.buffered());
    }
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{(Time{ .io = testing.io }).fmtAt(.date, tsFromMs(0))});
    try testing.expectEqualStrings("Thu Jan  1 00:00:00 UTC 1970", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{(Time{ .io = testing.io }).fmtAt(.log, tsFromMs(0))});
    try testing.expectEqualStrings("1970-01-01 00:00:00.000 UTC", w.buffered());
}
