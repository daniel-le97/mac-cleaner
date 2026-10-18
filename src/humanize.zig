//! Small, allocation-free formatting helpers used by the reporters.

const std = @import("std");

pub const ns_per_day: i96 = std.time.ns_per_day;

/// Formats a byte count into a compact human readable string such as "1.5 GB".
/// The result is written into `buf`; the returned slice points into `buf`.
pub fn bytes(buf: []u8, value: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB", "EB" };
    if (value < 1024) return std.fmt.bufPrint(buf, "{d} B", .{value}) catch "?";

    var v: f64 = @floatFromInt(value);
    var i: usize = 0;
    while (v >= 1024.0 and i + 1 < units.len) : (i += 1) v /= 1024.0;

    // Keep "1023.9 MB" from being printed when the value rounds up to 1024.
    if (v >= 1023.5 and i + 1 < units.len) {
        v /= 1024.0;
        i += 1;
    }

    if (v < 10.0) return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[i] }) catch "?";
    return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[i] }) catch "?";
}

/// Accepts plain digits, or a number with a K/M/G/T (base 1024) suffix.
pub fn parseBytes(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidSize;
    var digits = text;
    var multiplier: u64 = 1;
    const last = text[text.len - 1];
    switch (std.ascii.toUpper(last)) {
        'K' => {
            digits = text[0 .. text.len - 1];
            multiplier = 1 << 10;
        },
        'M' => {
            digits = text[0 .. text.len - 1];
            multiplier = 1 << 20;
        },
        'G' => {
            digits = text[0 .. text.len - 1];
            multiplier = 1 << 30;
        },
        'T' => {
            digits = text[0 .. text.len - 1];
            multiplier = 1 << 40;
        },
        'B' => {
            digits = text[0 .. text.len - 1];
        },
        else => {},
    }
    const n = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidSize;
    return std.math.mul(u64, n, multiplier);
}

/// Number of whole days between two nanosecond timestamps.
pub fn ageDays(now_ns: i96, then_ns: i96) u64 {
    const delta = now_ns - then_ns;
    if (delta <= 0) return 0;
    return @intCast(@divTrunc(delta, ns_per_day));
}

/// Writes `text` right aligned inside `width` columns.
pub fn writeAligned(w: *std.Io.Writer, text: []const u8, width: usize) std.Io.Writer.Error!void {
    if (text.len < width) try w.splatByteAll(' ', width - text.len);
    try w.writeAll(text);
}

/// Writes `text` left aligned inside `width` columns.
pub fn writeLeftAligned(w: *std.Io.Writer, text: []const u8, width: usize) std.Io.Writer.Error!void {
    try w.writeAll(text);
    if (text.len < width) try w.splatByteAll(' ', width - text.len);
}

/// "1 file" / "3 files".
pub fn files(buf: []u8, n: u64) []const u8 {
    if (n == 1) return std.fmt.bufPrint(buf, "{d} file", .{n}) catch "?";
    return std.fmt.bufPrint(buf, "{d} files", .{n}) catch "?";
}

/// "1 directory" / "3 directories".
pub fn directories(buf: []u8, n: u64) []const u8 {
    if (n == 1) return std.fmt.bufPrint(buf, "{d} directory", .{n}) catch "?";
    return std.fmt.bufPrint(buf, "{d} directories", .{n}) catch "?";
}

/// Truncates the front of a path so the interesting tail stays visible.
pub fn ellipsizeHead(buf: []u8, text: []const u8, max: usize) []const u8 {
    if (max < 4 or text.len <= max) return text;
    if (max > buf.len) return text;
    const keep = max - 3;
    @memcpy(buf[0..3], "...");
    @memcpy(buf[3 .. 3 + keep], text[text.len - keep ..]);
    return buf[0..max];
}

test "bytes formats common sizes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", bytes(&buf, 0));
    try std.testing.expectEqualStrings("512 B", bytes(&buf, 512));
    try std.testing.expectEqualStrings("1023 B", bytes(&buf, 1023));
    try std.testing.expectEqualStrings("1.0 KB", bytes(&buf, 1024));
    try std.testing.expectEqualStrings("1.5 KB", bytes(&buf, 1536));
    try std.testing.expectEqualStrings("10 KB", bytes(&buf, 10 * 1024));
    try std.testing.expectEqualStrings("1.0 MB", bytes(&buf, 1024 * 1024));
    try std.testing.expectEqualStrings("1.5 GB", bytes(&buf, 3 * 1024 * 1024 * 1024 / 2));
    try std.testing.expectEqualStrings("2.0 TB", bytes(&buf, 2 * 1024 * 1024 * 1024 * 1024));
}

test "bytes never reports 1024 of a unit" {
    var buf: [32]u8 = undefined;
    // 1023.9 MB would round to "1024 MB" if we did not bump the unit.
    const nearly_a_gib: u64 = 1024 * 1024 * 1024 - 1;
    try std.testing.expectEqualStrings("1.0 GB", bytes(&buf, nearly_a_gib));
}

test "parseBytes understands suffixes" {
    try std.testing.expectEqual(@as(u64, 1234), try parseBytes("1234"));
    try std.testing.expectEqual(@as(u64, 10 * 1024), try parseBytes("10K"));
    try std.testing.expectEqual(@as(u64, 5 * 1024 * 1024), try parseBytes("5M"));
    try std.testing.expectEqual(@as(u64, 7 * 1024 * 1024 * 1024), try parseBytes("7g"));
    try std.testing.expectError(error.InvalidSize, parseBytes("nope"));
    try std.testing.expectError(error.InvalidSize, parseBytes(""));
}

test "ageDays" {
    try std.testing.expectEqual(@as(u64, 0), ageDays(0, 0));
    try std.testing.expectEqual(@as(u64, 0), ageDays(0, ns_per_day));
    try std.testing.expectEqual(@as(u64, 3), ageDays(ns_per_day * 3, 0));
}

test "ellipsizeHead keeps the tail" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("short", ellipsizeHead(&buf, "short", 8));
    try std.testing.expectEqualStrings("...fghij", ellipsizeHead(&buf, "abcdefghij", 8));
}
