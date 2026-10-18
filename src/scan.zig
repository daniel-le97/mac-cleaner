//! Measures every rule and reports the result.

const std = @import("std");
const rules = @import("rules.zig");
const measure = @import("measure.zig");
const pathx = @import("pathx.zig");
const proc = @import("proc.zig");
const ui = @import("ui.zig");

pub const Result = struct {
    rule: rules.Rule,
    bytes: u64 = 0,
    files: u64 = 0,
    newest_mtime_ns: i96 = 0,
    /// Expanded paths that exist on this machine.
    paths: []const []const u8 = &.{},
    /// False when the item cannot be measured (command rules, root-only paths).
    sized: bool = false,
    /// Deletion needs sudo, so the tool only prints the command.
    needs_root: bool = false,
    /// Some locations existed but could not be read.
    partial: bool = false,

    pub fn commandLine(self: Result, arena: std.mem.Allocator) ![]const u8 {
        return rules.commandLine(arena, self.rule);
    }
};

pub const Options = struct {
    /// Only rules at or below this safety level are considered.
    level: rules.Safety = .risky,
    group: ?rules.Group = null,
    only: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    /// Skip measuring paths that need root, since we cannot delete them anyway.
    skip_root: bool = true,
};

pub fn contains(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn selected(rule: rules.Rule, opts: Options) bool {
    if (contains(opts.exclude, rule.id)) return false;
    if (opts.only.len != 0) return contains(opts.only, rule.id);
    if (opts.group) |group| {
        if (rule.group != group) return false;
    }
    return @intFromEnum(rule.safety) <= @intFromEnum(opts.level);
}

/// Runs every selected rule and returns the results sorted by size, largest
/// first. Nothing is deleted here.
pub fn run(ctx: *ui.Ctx, opts: Options) ![]Result {
    var results: std.ArrayList(Result) = .empty;

    var considered: usize = 0;
    for (rules.rules) |rule| {
        if (selected(rule, opts)) considered += 1;
    }

    if (!ctx.quiet and !ctx.json and !ctx.tty) {
        // Not a terminal: the per-location status line is invisible, so at
        // least say how much work is coming.
        ctx.note("measuring {d} locations, this can take a minute with large caches...\n", .{considered});
    }

    var index: usize = 0;
    for (rules.rules) |rule| {
        if (!selected(rule, opts)) continue;
        index += 1;
        if (ctx.verbose) {
            ctx.note("  [{d}/{d}] {s}\n", .{ index, considered, rule.title });
        } else {
            ctx.status("measuring {d}/{d}  {s}", .{ index, considered, rule.title });
        }

        var result: Result = .{ .rule = rule, .needs_root = rule.needs_root };

        if (rule.needs_root and opts.skip_root) {
            result.paths = try pathx.expand(ctx.arena, ctx.io, ctx.home, rule.paths[0]);
            try results.append(ctx.arena, result);
            continue;
        }

        switch (rule.kind) {
            .path => {
                var paths: std.ArrayList([]const u8) = .empty;
                for (rule.paths) |pattern| {
                    const expanded = try pathx.expand(ctx.arena, ctx.io, ctx.home, pattern);
                    for (expanded) |candidate| {
                        if (!measure.exists(ctx.io, candidate)) continue;
                        try paths.append(ctx.arena, candidate);

                        const measured = measure.measure(ctx.io, ctx.gpa, ctx.arena, candidate, rule.remove == .contents);
                        result.bytes += measured.bytes;
                        result.files += measured.files;
                        result.sized = true;
                        if (measured.unreadable != 0) result.partial = true;
                        if (measured.newest_mtime_ns > result.newest_mtime_ns) {
                            result.newest_mtime_ns = measured.newest_mtime_ns;
                        }
                    }
                }
                result.paths = try paths.toOwnedSlice(ctx.arena);
            },
            .command => {
                if (rule.probe.len != 0) {
                    const expanded = try pathx.expand(ctx.arena, ctx.io, ctx.home, rule.probe);
                    var paths: std.ArrayList([]const u8) = .empty;
                    for (expanded) |candidate| {
                        if (!measure.exists(ctx.io, candidate)) continue;
                        try paths.append(ctx.arena, candidate);
                        const measured = measure.measure(ctx.io, ctx.gpa, ctx.arena, candidate, false);
                        result.bytes += measured.bytes;
                        result.files += measured.files;
                        result.sized = true;
                        if (measured.unreadable != 0) result.partial = true;
                    }
                    result.paths = try paths.toOwnedSlice(ctx.arena);
                } else {
                    result.paths = try ctx.arena.dupe([]const u8, &.{});
                }
            },
        }

        try results.append(ctx.arena, result);
    }

    ctx.clearStatus();

    const owned = try results.toOwnedSlice(ctx.arena);
    try subtractOverlaps(owned);
    std.sort.heap(Result, owned, {}, struct {
        fn lessThan(_: void, a: Result, b: Result) bool {
            if (a.bytes != b.bytes) return a.bytes > b.bytes;
            // Pure actions (docker prune, tmutil, ...) have no measurable size,
            // so keep them below the real findings and sort them by id.
            const a_cmd = a.rule.kind == .command;
            const b_cmd = b.rule.kind == .command;
            if (a_cmd != b_cmd) return b_cmd;
            return std.mem.lessThan(u8, a.rule.id, b.rule.id);
        }
    }.lessThan);
    return owned;
}

/// Umbrella rules (`remainder = true`) report the space that no other rule
/// already accounted for.
fn subtractOverlaps(results: []Result) !void {
    for (results, 0..) |*result, i| {
        if (!result.rule.remainder or result.paths.len == 0) continue;
        const base = std.mem.trimEnd(u8, result.paths[0], "/");

        var claimed: u64 = 0;
        for (results, 0..) |other, j| {
            if (i == j or other.rule.remainder) continue;
            for (other.paths) |path| {
                if (isInside(path, base)) {
                    claimed +|= other.bytes;
                    break;
                }
            }
        }
        result.bytes -|= @min(result.bytes, claimed);
    }
}

pub fn isInside(path: []const u8, base: []const u8) bool {
    if (!std.mem.startsWith(u8, path, base)) return false;
    if (path.len == base.len) return true;
    const next = path[base.len];
    return next == '/' or next == '\\';
}

pub const Totals = struct {
    total: u64 = 0,
    safe: u64 = 0,
    recreatable: u64 = 0,
    risky: u64 = 0,
    pending_root: u64 = 0,

    pub fn add(self: *Totals, result: Result) void {
        self.total += result.bytes;
        switch (result.rule.safety) {
            .safe => self.safe += result.bytes,
            .recreatable => self.recreatable += result.bytes,
            .risky => self.risky += result.bytes,
        }
    }
};

pub fn totals(results: []const Result) Totals {
    var t: Totals = .{};
    for (results) |result| t.add(result);
    return t;
}

test "isInside only matches real path prefixes" {
    try std.testing.expect(isInside("/a/b/c", "/a/b"));
    try std.testing.expect(isInside("/a/b", "/a/b"));
    try std.testing.expect(!isInside("/a/bc", "/a/b"));
    try std.testing.expect(!isInside("/a", "/a/b"));
}

test "contains" {
    const list = [_][]const u8{ "a", "b" };
    try std.testing.expect(contains(&list, "b"));
    try std.testing.expect(!contains(&list, "c"));
}

test "subtractOverlaps removes claimed bytes" {
    var results = [_]Result{
        .{
            .rule = .{ .id = "umbrella", .title = "u", .group = .system, .safety = .recreatable, .remainder = true },
            .bytes = 100,
            .paths = &.{"/caches"},
        },
        .{
            .rule = .{ .id = "child", .title = "c", .group = .system, .safety = .safe },
            .bytes = 40,
            .paths = &.{"/caches/app"},
        },
        .{
            .rule = .{ .id = "elsewhere", .title = "e", .group = .system, .safety = .safe },
            .bytes = 25,
            .paths = &.{"/other"},
        },
    };
    try subtractOverlaps(&results);
    try std.testing.expectEqual(@as(u64, 60), results[0].bytes);
    try std.testing.expectEqual(@as(u64, 40), results[1].bytes);
}

test "subtractOverlaps never underflows" {
    var results = [_]Result{
        .{
            .rule = .{ .id = "umbrella", .title = "u", .group = .system, .safety = .recreatable, .remainder = true },
            .bytes = 10,
            .paths = &.{"/caches"},
        },
        .{
            .rule = .{ .id = "child", .title = "c", .group = .system, .safety = .safe },
            .bytes = 40,
            .paths = &.{"/caches/app"},
        },
    };
    try subtractOverlaps(&results);
    try std.testing.expectEqual(@as(u64, 0), results[0].bytes);
}
