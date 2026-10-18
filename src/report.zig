//! Rendering of scan results as a table or JSON.

const std = @import("std");
const humanize = @import("humanize.zig");
const rules = @import("rules.zig");
const scan = @import("scan.zig");
const ui = @import("ui.zig");

pub const RenderOptions = struct {
    heading: []const u8 = "",
    /// Show rules that matched nothing, useful with `--only`.
    show_empty: bool = false,
};

fn isInteresting(result: scan.Result) bool {
    if (result.needs_root) return true;
    if (result.rule.kind == .command) return true;
    return result.paths.len != 0 and result.bytes > 0;
}

pub fn renderScan(ctx: *ui.Ctx, results: []const scan.Result, opts: RenderOptions) !void {
    if (ctx.json) return renderJson(ctx, results, opts);

    const t = scan.totals(results);
    if (opts.heading.len != 0) try ui.title(ctx, opts.heading);

    try ui.header(ctx, true, "ITEM");

    var shown: usize = 0;
    for (results) |result| {
        if (!opts.show_empty and !isInteresting(result)) continue;
        shown += 1;

        var size_buf: [32]u8 = undefined;
        const detail = if (result.rule.kind == .command)
            try result.commandLine(ctx.arena)
        else if (result.paths.len != 0)
            result.paths[0]
        else
            "";

        try ui.row(ctx, &size_buf, result.bytes, result.sized, result.rule.safety, result.rule.group, result.rule.title, detail);

        if (ctx.verbose) {
            if (result.rule.why.len != 0) try ui.indent(ctx, result.rule.why);
            if (result.rule.kind == .path and result.paths.len > 1) {
                for (result.paths[1..]) |path| try ui.indent(ctx, path);
            }
            if (result.partial) try ui.indent(ctx, "(some locations were not readable)");
        }
    }

    if (shown == 0) {
        try ctx.paint(ui.dim);
        try ctx.out.writeAll("  nothing found here - nice.\n");
        try ctx.reset();
        return;
    }

    try renderTotals(ctx, t);
}

pub fn renderTotals(ctx: *ui.Ctx, t: scan.Totals) !void {
    if (t.total == 0) return;

    try ctx.out.print("\n", .{});
    try ui.ruler(ctx, 74);

    var total_buf: [32]u8 = undefined;
    try ctx.paint(ui.bold);
    try humanize.writeAligned(ctx.out, humanize.bytes(&total_buf, t.total), ui.columns.size);
    try ctx.reset();
    try ctx.out.print("  total found\n", .{});

    try renderLevel(ctx, t.safe, .safe);
    try renderLevel(ctx, t.recreatable, .recreatable);
    try renderLevel(ctx, t.risky, .risky);

    var safe_buf: [32]u8 = undefined;
    var middle_buf: [32]u8 = undefined;
    var all_buf: [32]u8 = undefined;

    try ctx.out.print("\n  ", .{});
    try ctx.paint(ui.dim);
    try ctx.out.writeAll("if you delete:");
    try ctx.reset();
    try ctx.out.writeAll("   safe ");
    try ctx.paint(ui.green);
    try ctx.out.writeAll(humanize.bytes(&safe_buf, t.safe));
    try ctx.reset();
    try ctx.out.writeAll("   + caches ");
    try ctx.paint(ui.yellow);
    try ctx.out.writeAll(humanize.bytes(&middle_buf, t.safe +| t.recreatable));
    try ctx.reset();
    try ctx.out.writeAll("   everything ");
    try ctx.paint(ui.red);
    try ctx.out.writeAll(humanize.bytes(&all_buf, t.total));
    try ctx.reset();
    try ctx.out.print("\n", .{});
}

fn renderLevel(ctx: *ui.Ctx, bytes: u64, safety: rules.Safety) !void {
    var buf: [32]u8 = undefined;
    try ctx.out.print("  ", .{});
    try humanize.writeAligned(ctx.out, humanize.bytes(&buf, bytes), ui.columns.size);
    try ctx.out.print("  ", .{});
    try ctx.paint(ui.safetyColor(safety));
    try humanize.writeLeftAligned(ctx.out, safety.label(), ui.columns.safety);
    try ctx.reset();
    try ctx.out.print("  ", .{});
    try ctx.paint(ui.dim);
    try ctx.out.writeAll(safety.description());
    try ctx.reset();
    try ctx.out.print("\n", .{});
}

pub fn writeJsonString(ctx: *ui.Ctx, text: []const u8) !void {
    try ctx.out.writeByte('"');
    for (text) |byte| switch (byte) {
        '"' => try ctx.out.writeAll("\\\""),
        '\\' => try ctx.out.writeAll("\\\\"),
        '\n' => try ctx.out.writeAll("\\n"),
        '\r' => try ctx.out.writeAll("\\r"),
        '\t' => try ctx.out.writeAll("\\t"),
        else => {
            if (byte < 0x20) {
                try ctx.out.print("\\u{x:0>4}", .{byte});
            } else {
                try ctx.out.writeByte(byte);
            }
        },
    };
    try ctx.out.writeByte('"');
}

/// Writes the elements of the items array, without the surrounding brackets.
pub fn writeJsonItems(ctx: *ui.Ctx, results: []const scan.Result, show_empty: bool) !void {
    var first = true;
    for (results) |result| {
        if (!show_empty and !isInteresting(result)) continue;
        try ctx.out.writeAll(if (first) "\n" else ",\n");
        first = false;
        try ctx.out.writeAll("    {\"id\": ");
        try writeJsonString(ctx, result.rule.id);
        try ctx.out.writeAll(", \"title\": ");
        try writeJsonString(ctx, result.rule.title);
        try ctx.out.writeAll(", \"group\": ");
        try writeJsonString(ctx, result.rule.group.label());
        try ctx.out.writeAll(", \"safety\": ");
        try writeJsonString(ctx, result.rule.safety.label());
        try ctx.out.print(", \"bytes\": {d}, \"files\": {d}, \"sized\": {}, \"needs_root\": {}, \"paths\": [", .{
            result.bytes,
            result.files,
            result.sized,
            result.needs_root,
        });
        for (result.paths, 0..) |path, i| {
            if (i != 0) try ctx.out.writeAll(", ");
            try writeJsonString(ctx, path);
        }
        try ctx.out.writeAll("]}");
    }
    if (!first) try ctx.out.writeAll("\n  ");
}

pub fn renderJson(ctx: *ui.Ctx, results: []const scan.Result, opts: RenderOptions) !void {
    const t = scan.totals(results);

    try ctx.out.print("{{\n  \"generated_by\": \"mac-cleaner\",\n", .{});
    if (opts.heading.len != 0) {
        try ctx.out.writeAll("  \"heading\": ");
        try writeJsonString(ctx, opts.heading);
        try ctx.out.print(",\n", .{});
    }
    try ctx.out.print("  \"total_bytes\": {d},\n", .{t.total});
    try ctx.out.print("  \"safe_bytes\": {d},\n", .{t.safe});
    try ctx.out.print("  \"recreatable_bytes\": {d},\n", .{t.recreatable});
    try ctx.out.print("  \"risky_bytes\": {d},\n", .{t.risky});
    try ctx.out.writeAll("  \"items\": [");
    try writeJsonItems(ctx, results, opts.show_empty);
    try ctx.out.writeAll("]\n}\n");
}

test "renderJson produces parsable output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var err_writer = std.Io.Writer.fixed(&out_buf);

    var ctx: ui.Ctx = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .out = &out_writer,
        .err = &err_writer,
        .home = "/Users/me",
        .color = false,
        .json = true,
    };

    const results = [_]scan.Result{
        .{
            .rule = .{ .id = "test", .title = "Test \"rule\"", .group = .system, .safety = .safe },
            .bytes = 1234,
            .sized = true,
            .paths = &.{"/a/b"},
        },
    };
    try renderJson(&ctx, &results, .{});

    const json_text = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"total_bytes\": 1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"id\": \"test\"") != null);
    // Embedded quotes must be escaped.
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"title\": \"Test \\\"rule\\\"\"") != null);
}
