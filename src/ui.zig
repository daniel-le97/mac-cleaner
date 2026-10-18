//! Terminal output helpers: shared context, colours and tables.

const std = @import("std");
const humanize = @import("humanize.zig");
const rules = @import("rules.zig");

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    home: []const u8,
    /// Written by cli parsing, set to false when `--no-color` is used or the
    /// output is not a terminal.
    color: bool = true,
    json: bool = false,
    verbose: bool = false,
    quiet: bool = false,
    show_paths: bool = true,
    /// stdout is a terminal.
    tty: bool = false,
    /// Draw a live progress line on stderr.
    progress: bool = false,

    pub fn paint(self: *const Ctx, code: []const u8) std.Io.Writer.Error!void {
        if (self.color) try self.out.writeAll(code);
    }

    pub fn reset(self: *const Ctx) std.Io.Writer.Error!void {
        if (self.color) try self.out.writeAll(reset_code);
    }

    /// Prints a transient status line on stderr, only when it would help.
    pub fn status(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        if (!self.progress or self.json or self.quiet) return;
        self.err.print("\r\x1b[K  " ++ fmt, args) catch return;
        self.err.flush() catch {};
    }

    pub fn clearStatus(self: *Ctx) void {
        if (!self.progress or self.json or self.quiet) return;
        self.err.writeAll("\r\x1b[K") catch return;
        self.err.flush() catch {};
    }

    pub fn note(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        self.err.print(fmt, args) catch return;
        self.err.flush() catch {};
    }
};

pub const reset_code = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const red = "\x1b[31m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const blue = "\x1b[34m";
pub const magenta = "\x1b[35m";
pub const cyan = "\x1b[36m";

pub fn safetyColor(safety: rules.Safety) []const u8 {
    return switch (safety) {
        .safe => green,
        .recreatable => yellow,
        .risky => red,
    };
}

pub fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .real).nanoseconds;
}

pub fn title(ctx: *Ctx, text: []const u8) !void {
    try ctx.out.print("\n", .{});
    try ctx.paint(bold);
    try ctx.out.writeAll(text);
    try ctx.reset();
    try ctx.out.print("\n", .{});
}

/// Column layout shared by the report tables.
pub const columns = .{
    .size = 9,
    .safety = 11,
    .group = 10,
};

pub fn header(ctx: *Ctx, with_size: bool, what: []const u8) !void {
    try ctx.paint(dim);
    if (with_size) {
        try humanize.writeAligned(ctx.out, "SIZE", columns.size);
        try ctx.out.print("  ", .{});
    }
    try humanize.writeLeftAligned(ctx.out, "SAFETY", columns.safety);
    try ctx.out.print("  ", .{});
    try humanize.writeLeftAligned(ctx.out, "GROUP", columns.group);
    try ctx.out.print("  ", .{});
    try ctx.out.writeAll(what);
    try ctx.reset();
    try ctx.out.print("\n", .{});
}

pub fn ruler(ctx: *Ctx, width: usize) !void {
    try ctx.paint(dim);
    try ctx.out.splatByteAll('-', width);
    try ctx.reset();
    try ctx.out.print("\n", .{});
}

/// One report row: size, safety, group, title and (optionally) the path.
pub fn row(
    ctx: *Ctx,
    size_buf: *[32]u8,
    bytes: u64,
    sized: bool,
    safety: rules.Safety,
    group: rules.Group,
    label: []const u8,
    detail: []const u8,
) !void {
    const size_text = if (sized) humanize.bytes(size_buf, bytes) else "-";
    try humanize.writeAligned(ctx.out, size_text, columns.size);
    try ctx.out.print("  ", .{});

    try ctx.paint(safetyColor(safety));
    try humanize.writeLeftAligned(ctx.out, safety.label(), columns.safety);
    try ctx.reset();
    try ctx.out.print("  ", .{});

    try ctx.paint(dim);
    try humanize.writeLeftAligned(ctx.out, group.label(), columns.group);
    try ctx.reset();
    try ctx.out.print("  ", .{});

    try ctx.out.writeAll(label);

    if (ctx.show_paths and detail.len > 0) {
        var trunc_buf: [96]u8 = undefined;
        const shown = humanize.ellipsizeHead(&trunc_buf, detail, 78);
        try ctx.out.print("  ", .{});
        try ctx.paint(dim);
        try ctx.out.writeAll(shown);
        try ctx.reset();
    }
    try ctx.out.print("\n", .{});
}

pub fn indent(ctx: *Ctx, text: []const u8) !void {
    try ctx.out.print("    ", .{});
    try ctx.paint(dim);
    try ctx.out.writeAll(text);
    try ctx.reset();
    try ctx.out.print("\n", .{});
}

test "safety colours are distinct" {
    try std.testing.expect(!std.mem.eql(u8, safetyColor(.safe), safetyColor(.risky)));
    try std.testing.expect(!std.mem.eql(u8, safetyColor(.safe), safetyColor(.recreatable)));
}
