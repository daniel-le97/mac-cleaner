//! Disk overview and actionable advice.

const std = @import("std");
const builtin = @import("builtin");
const humanize = @import("humanize.zig");
const proc = @import("proc.zig");
const scan = @import("scan.zig");
const ui = @import("ui.zig");

pub const Disk = struct {
    total: u64 = 0,
    used: u64 = 0,
    available: u64 = 0,
    ok: bool = false,

    pub fn usedPercent(self: Disk) u8 {
        if (self.total == 0) return 0;
        return @intCast(@min(@as(u64, 100), self.used * 100 / self.total));
    }
};

/// Reads `df -k /` so the tool works the same on macOS and Linux without
/// platform specific syscalls.
pub fn disk(ctx: *ui.Ctx) Disk {
    const out = proc.run(ctx, &.{ "df", "-k", "/" });
    if (!out.ok) return .{};

    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    _ = lines.next() orelse return .{};
    const line = lines.next() orelse return .{};

    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    _ = tokens.next() orelse return .{};
    const total_k = std.fmt.parseInt(u64, tokens.next() orelse return .{}, 10) catch return .{};
    const used_k = std.fmt.parseInt(u64, tokens.next() orelse return .{}, 10) catch return .{};
    const avail_k = std.fmt.parseInt(u64, tokens.next() orelse return .{}, 10) catch return .{};

    return .{
        .total = total_k * 1024,
        .used = used_k * 1024,
        .available = avail_k * 1024,
        .ok = true,
    };
}

pub fn localSnapshots(ctx: *ui.Ctx) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const out = proc.run(ctx, &.{ "tmutil", "listlocalsnapshots", "/" });
    if (!out.ok) return list.toOwnedSlice(ctx.arena);

    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "com.apple.TimeMachine") == null) continue;
        try list.append(ctx.arena, line);
    }
    return list.toOwnedSlice(ctx.arena);
}

pub fn macosVersion(ctx: *ui.Ctx) ?[]const u8 {
    return proc.firstLine(ctx, &.{ "sw_vers", "-productVersion" });
}

/// One line summary of free space, used under scan/du output.
pub fn printDiskLine(ctx: *ui.Ctx) !void {
    const info = disk(ctx);
    if (!info.ok) return;

    var avail_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;

    try ctx.out.print("\n", .{});
    try ctx.paint(ui.dim);
    try ctx.out.writeAll("  disk ");
    try ctx.reset();
    try ctx.paint(if (info.available < 25 << 30) ui.red else ui.green);
    try ctx.out.writeAll(humanize.bytes(&avail_buf, info.available));
    try ctx.reset();
    try ctx.out.writeAll(" available of ");
    try ctx.out.writeAll(humanize.bytes(&total_buf, info.total));
    try ctx.out.print("\n", .{});
}

fn bar(ctx: *ui.Ctx, percent: u8) !void {
    const width: usize = 32;
    const filled = width * percent / 100;
    try ctx.paint(if (percent >= 90) ui.red else if (percent >= 75) ui.yellow else ui.green);
    try ctx.out.splatByteAll('#', filled);
    try ctx.reset();
    try ctx.paint(ui.dim);
    try ctx.out.splatByteAll('.', width - filled);
    try ctx.reset();
}

pub fn run(ctx: *ui.Ctx, results: []const scan.Result) !void {
    const disk_info = disk(ctx);
    const snapshots = try localSnapshots(ctx);
    const version = macosVersion(ctx);

    if (ctx.json) {
        try ctx.out.print("{{\n  \"total_bytes\": {d},\n  \"used_bytes\": {d},\n  \"available_bytes\": {d},\n  \"snapshots\": {d}\n}}\n", .{
            disk_info.total,
            disk_info.used,
            disk_info.available,
            snapshots.len,
        });
        return;
    }

    try ui.title(ctx, "Disk");

    if (builtin.os.tag != .macos) {
        try ctx.paint(ui.yellow);
        try ctx.out.writeAll("  note: this binary was built for ");
        try ctx.out.writeAll(@tagName(builtin.os.tag));
        try ctx.out.writeAll(", so macOS only locations will not exist here.\n");
        try ctx.reset();
    } else if (version) |v| {
        try ctx.out.print("  macOS {s} ({s})\n", .{ v, @tagName(builtin.cpu.arch) });
    }

    if (disk_info.ok) {
        var total_buf: [32]u8 = undefined;
        var used_buf: [32]u8 = undefined;
        var avail_buf: [32]u8 = undefined;
        const percent = disk_info.usedPercent();

        try ctx.out.print("  ", .{});
        try bar(ctx, percent);
        try ctx.out.print("  {d}% used\n", .{percent});
        try ctx.out.print("  {s} of {s} used, ", .{
            humanize.bytes(&used_buf, disk_info.used),
            humanize.bytes(&total_buf, disk_info.total),
        });
        try ctx.paint(if (disk_info.available < 25 << 30) ui.red else ui.green);
        try ctx.out.writeAll(humanize.bytes(&avail_buf, disk_info.available));
        try ctx.reset();
        try ctx.out.writeAll(" available\n");

        if (disk_info.available < 10 << 30) {
            try ctx.paint(ui.red);
            try ctx.out.writeAll("  critically low: a macOS update needs 20-30 GB free before it will even start.\n");
            try ctx.reset();
        } else if (disk_info.available < 25 << 30) {
            try ctx.paint(ui.yellow);
            try ctx.out.writeAll("  low: free up 30 GB before the next macOS update.\n");
            try ctx.reset();
        }
    } else {
        try ctx.paint(ui.dim);
        try ctx.out.writeAll("  could not read disk usage from `df`.\n");
        try ctx.reset();
    }

    if (builtin.os.tag == .macos) {
        try ctx.out.print("  local Time Machine snapshots: {d}\n", .{snapshots.len});
        if (snapshots.len != 0) {
            try ctx.paint(ui.dim);
            try ctx.out.writeAll("    `sudo tmutil listlocalsnapshots /` shows them; they are one of the biggest wins on a full disk.\n");
            try ctx.reset();
        }
    }

    // ------------------------------------------------------------- top targets
    var shown: usize = 0;
    try ui.title(ctx, "Biggest reclaimable items");
    try ui.header(ctx, true, "ITEM");
    for (results) |result| {
        if (result.bytes == 0) continue;
        var size_buf: [32]u8 = undefined;
        const detail = if (result.paths.len != 0) result.paths[0] else "";
        try ui.row(ctx, &size_buf, result.bytes, result.sized, result.rule.safety, result.rule.group, result.rule.title, detail);
        shown += 1;
        if (shown == 10) break;
    }
    if (shown == 0) {
        try ctx.paint(ui.dim);
        try ctx.out.writeAll("  nothing measurable found.\n");
        try ctx.reset();
    }

    // ----------------------------------------------------------- what to do
    try ui.title(ctx, "Suggested order");
    var step: usize = 1;

    if (snapshots.len != 0) {
        try ctx.out.print("  {d}. remove local snapshots      ", .{step});
        try ctx.paint(ui.dim);
        try ctx.out.writeAll("mac-cleaner clean --only time-machine-snapshots --apply\n");
        try ctx.reset();
        step += 1;
    }

    const budget: u64 = 40 << 30;
    var reclaimed: u64 = 0;
    var chosen: std.ArrayList([]const u8) = .empty;
    while (chosen.items.len < 4) {
        var best: ?scan.Result = null;
        for (results) |result| {
            if (result.bytes == 0) continue;
            if (scan.contains(chosen.items, result.rule.id)) continue;
            if (best == null or result.bytes > best.?.bytes) best = result;
        }
        const pick = best orelse break;
        try chosen.append(ctx.arena, pick.rule.id);

        try ctx.out.print("  {d}. {s:<28}", .{ step, pick.rule.title });
        try ctx.paint(ui.dim);
        try ctx.out.print("[{s}] mac-cleaner clean --only {s} --apply\n", .{ pick.rule.safety.label(), pick.rule.id });
        try ctx.reset();

        reclaimed += pick.bytes;
        step += 1;
        if (reclaimed >= budget) break;
    }

    if (step == 1) {
        try ctx.paint(ui.dim);
        try ctx.out.writeAll("  nothing obvious to delete. Try `mac-cleaner artifacts` or `mac-cleaner big`.\n");
        try ctx.reset();
    }

    try ui.title(ctx, "Safety");
    try ctx.paint(ui.dim);
    try ctx.out.writeAll("  deletions are restricted to your home folder.\n");
    try ctx.out.writeAll("  macOS owned paths are reported for information only and are never modified,\n");
    try ctx.out.writeAll("  so there is no way to break the OS with this tool.\n");
    try ctx.reset();
}

pub const advice = [_][]const u8{
    "Run `mac-cleaner artifacts` to find node_modules / target / .zig-cache across all your projects.",
    "Run `mac-cleaner big` to see the largest individual files on the machine.",
    "`mac-cleaner du ~` shows which home directory folders are eating the disk.",
};

test "usedPercent" {
    const d: Disk = .{ .total = 100, .used = 92, .available = 8, .ok = true };
    try std.testing.expectEqual(@as(u8, 92), d.usedPercent());
    const empty: Disk = .{};
    try std.testing.expectEqual(@as(u8, 0), empty.usedPercent());
}
