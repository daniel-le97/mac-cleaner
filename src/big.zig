//! Largest files and directory breakdowns.

const std = @import("std");
const humanize = @import("humanize.zig");
const measure = @import("measure.zig");
const ui = @import("ui.zig");

pub const FileEntry = struct {
    path: []const u8,
    bytes: u64 = 0,
    mtime_ns: i96 = 0,
};

/// Keeps the `limit` largest files seen while walking `root`.
pub fn topFiles(ctx: *ui.Ctx, root: []const u8, limit: usize, min_bytes: u64) ![]FileEntry {
    var entries: std.ArrayList(FileEntry) = .empty;
    if (limit == 0) return entries.toOwnedSlice(ctx.arena);

    var dir = std.Io.Dir.openDirAbsolute(ctx.io, root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        ctx.note("cannot read {s}: {s}\n", .{ root, @errorName(err) });
        return entries.toOwnedSlice(ctx.arena);
    };
    defer dir.close(ctx.io);

    var walker = try dir.walkSelectively(ctx.gpa);
    defer walker.deinit();

    var smallest: usize = 0;
    var seen: u64 = 0;

    while (true) {
        const maybe_entry = walker.next(ctx.io) catch |err| switch (err) {
            error.OutOfMemory => break,
            else => continue,
        };
        const entry = maybe_entry orelse break;

        if (entry.kind == .directory) {
            walker.enter(ctx.io, entry) catch {};
            continue;
        }
        if (entry.kind != .file) continue;

        const st = entry.dir.statFile(ctx.io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        if (st.size < min_bytes) continue;
        seen += 1;
        if (entries.items.len == limit and st.size <= entries.items[smallest].bytes) continue;

        const candidate: FileEntry = .{
            .path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ root, entry.path }),
            .bytes = st.size,
            .mtime_ns = st.mtime.nanoseconds,
        };

        if (entries.items.len < limit) {
            try entries.append(ctx.arena, candidate);
            if (entries.items.len == limit) smallest = indexOfSmallest(entries.items);
        } else {
            entries.items[smallest] = candidate;
            smallest = indexOfSmallest(entries.items);
        }
    }

    if (ctx.verbose) ctx.note("  examined {d} files under {s}\n", .{ seen, root });

    const owned = try entries.toOwnedSlice(ctx.arena);
    std.sort.heap(FileEntry, owned, {}, struct {
        fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
            return a.bytes > b.bytes;
        }
    }.lessThan);
    return owned;
}

fn indexOfSmallest(entries: []const FileEntry) usize {
    var index: usize = 0;
    for (entries, 0..) |entry, i| {
        if (entry.bytes < entries[index].bytes) index = i;
    }
    return index;
}

pub fn renderFiles(ctx: *ui.Ctx, root: []const u8, entries: []const FileEntry) !void {
    const now = ui.nowNs(ctx.io);

    if (ctx.json) {
        try ctx.out.writeAll("{\n  \"files\": [");
        var first = true;
        for (entries) |entry| {
            try ctx.out.writeAll(if (first) "\n" else ",\n");
            first = false;
            try ctx.out.print("    {{\"path\": \"{s}\", \"bytes\": {d}}}", .{ entry.path, entry.bytes });
        }
        try ctx.out.writeAll(if (first) "]\n}\n" else "\n  ]\n}\n");
        return;
    }

    try ui.title(ctx, try std.fmt.allocPrint(ctx.arena, "Largest files under {s}", .{root}));

    var total: u64 = 0;
    for (entries) |entry| {
        var size_buf: [32]u8 = undefined;
        var age_buf: [32]u8 = undefined;
        const age_text = std.fmt.bufPrint(&age_buf, "{d}d ago", .{humanize.ageDays(now, entry.mtime_ns)}) catch "";

        try humanize.writeAligned(ctx.out, humanize.bytes(&size_buf, entry.bytes), ui.columns.size);
        try ctx.out.print("  ", .{});
        try ctx.paint(ui.dim);
        try humanize.writeAligned(ctx.out, age_text, ui.columns.safety);
        try ctx.reset();
        try ctx.out.print("  {s}\n", .{entry.path});
        total += entry.bytes;
    }

    if (entries.len == 0) {
        try ctx.paint(ui.dim);
        try ctx.out.writeAll("  nothing found.\n");
        try ctx.reset();
        return;
    }

    var buf: [32]u8 = undefined;
    try ctx.out.print("\n", .{});
    try ui.ruler(ctx, 74);
    try ctx.paint(ui.dim);
    try ctx.out.writeAll("top ");
    try ctx.out.print("{d} files hold ", .{entries.len});
    try ctx.paint(ui.bold);
    try ctx.out.writeAll(humanize.bytes(&buf, total));
    try ctx.reset();
    try ctx.out.print("\n", .{});
}

pub const DirEntry = struct {
    path: []const u8,
    name: []const u8,
    totals: measure.Totals,
};

/// Sizes every direct child of `root`, largest first.
pub fn dirBreakdown(ctx: *ui.Ctx, root: []const u8, limit: usize) ![]DirEntry {
    var out: std.ArrayList(DirEntry) = .empty;

    const children = measure.listChildren(ctx.io, ctx.arena, root) catch |err| {
        ctx.note("cannot read {s}: {s}\n", .{ root, @errorName(err) });
        return out.toOwnedSlice(ctx.arena);
    };

    for (children) |child| {
        ctx.status("measuring {s}", .{child});
        const totals = measure.measure(ctx.io, ctx.gpa, ctx.arena, child, false);
        try out.append(ctx.arena, .{
            .path = child,
            .name = std.fs.path.basename(child),
            .totals = totals,
        });
    }
    ctx.clearStatus();

    const owned = try out.toOwnedSlice(ctx.arena);
    std.sort.heap(DirEntry, owned, {}, struct {
        fn lessThan(_: void, a: DirEntry, b: DirEntry) bool {
            return a.totals.bytes > b.totals.bytes;
        }
    }.lessThan);
    return if (owned.len > limit) owned[0..limit] else owned;
}

pub fn renderDirs(ctx: *ui.Ctx, root: []const u8, entries: []const DirEntry) !void {
    if (ctx.json) {
        try ctx.out.writeAll("{\n  \"directories\": [");
        var first = true;
        for (entries) |entry| {
            try ctx.out.writeAll(if (first) "\n" else ",\n");
            first = false;
            try ctx.out.print("    {{\"path\": \"{s}\", \"bytes\": {d}}}", .{ entry.path, entry.totals.bytes });
        }
        try ctx.out.writeAll(if (first) "]\n}\n" else "\n  ]\n}\n");
        return;
    }

    try ui.title(ctx, try std.fmt.allocPrint(ctx.arena, "Directory sizes in {s}", .{root}));

    var total: u64 = 0;
    for (entries) |entry| {
        var size_buf: [32]u8 = undefined;
        var file_buf: [32]u8 = undefined;

        try humanize.writeAligned(ctx.out, humanize.bytes(&size_buf, entry.totals.bytes), ui.columns.size);
        try ctx.out.print("  ", .{});
        try ctx.paint(ui.dim);
        try humanize.writeLeftAligned(ctx.out, humanize.files(&file_buf, entry.totals.files), 14);
        try ctx.reset();
        try ctx.out.print("  {s}\n", .{entry.path});
        total += entry.totals.bytes;
    }

    var buf: [32]u8 = undefined;
    try ctx.out.print("\n", .{});
    try ui.ruler(ctx, 74);
    try ctx.paint(ui.bold);
    try humanize.writeAligned(ctx.out, humanize.bytes(&buf, total), ui.columns.size);
    try ctx.reset();
    try ctx.out.print("  across {d} entries\n", .{entries.len});
}

test "indexOfSmallest" {
    const entries = [_]FileEntry{
        .{ .path = "a", .bytes = 10 },
        .{ .path = "b", .bytes = 3 },
        .{ .path = "c", .bytes = 40 },
    };
    try std.testing.expectEqual(@as(usize, 1), indexOfSmallest(&entries));
}
