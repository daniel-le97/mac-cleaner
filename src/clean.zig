//! Deletion of the data behind scan results, with hard safety rails.

const std = @import("std");
const builtin = @import("builtin");
const humanize = @import("humanize.zig");
const rules = @import("rules.zig");
const scan = @import("scan.zig");
const measure = @import("measure.zig");
const proc = @import("proc.zig");
const ui = @import("ui.zig");
const report = @import("report.zig");

pub const Options = struct {
    level: rules.Safety = .recreatable,
    only: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    apply: bool = false,
};

pub const Status = enum {
    deleted,
    partially_deleted,
    failed,
    skipped_protected,
    root_required,
    command_ran,
    command_failed,
    command_missing,
};

pub const Outcome = struct {
    id: []const u8,
    title: []const u8,
    bytes: u64,
    status: Status,
    detail: []const u8 = "",
};

/// Absolute paths that are never deleted. In practice the "inside $HOME" rule
/// below already covers all of them; this list is a second line of defence
/// against a mistaken home directory.
const protected_paths = [_][]const u8{
    "/",     "/Users",   "/System", "/Library", "/Applications",
    "/usr",  "/bin",     "/sbin",   "/etc",     "/private",
    "/opt",  "/var",     "/tmp",    "/Volumes", "/dev",
    "/home", "/Network", "/net",    "/cores",   "/usr/local",
};

/// Exact home entries that are never deleted (the folder itself). The usual
/// developer source folders are in here too: rules and the artifact scanner
/// only ever delete *inside* them, never the folder itself.
const protected_home_exact = [_][]const u8{
    "Library",      "Desktop",  "Documents",        "Downloads",    "Movies",
    "Music",        "Pictures", "Public",           "Applications", "Dropbox",
    "Google Drive", "OneDrive", "iCloud Drive",     "Trash",        "code",
    "src",          "dev",      "Developer",        "projects",     "repos",
    "work",         "git",      "Documents/GitHub",
};

/// Anything below these home relative paths is never deleted, so credentials,
/// keychains, mail and browser profiles stay untouched even if a rule or a
/// wildcard is wrong.
const protected_home_prefix = [_][]const u8{
    // credentials and secrets
    ".ssh",
    ".gnupg",
    ".aws",
    ".azure",
    ".config",
    ".password-store",
    ".local/share/keyrings",
    ".netrc",
    ".npmrc",
    ".gitconfig",
    ".git-credentials",
    ".kube/config",
    ".docker/config.json",
    ".zsh_history",
    ".bash_history",
    // user data and identifiers
    "Library/Keychains",
    "Library/Preferences",
    "Library/Accounts",
    "Library/Calendars",
    "Library/Contacts",
    "Library/Mail",
    "Library/Messages",
    "Library/Safari",
    "Library/CloudStorage",
    "Library/Mobile Documents",
    "Library/Group Containers",
    "Library/Photos",
    "Library/Suggestions",
    "Library/Metadata",
    "Library/IdentityServices",
    "Library/Application Support/AddressBook",
    "Library/Application Support/com.apple.TCC",
    "Library/Application Support/com.apple.sharedfilelist",
    "Library/Application Support/Knowledge",
    "Library/Application Support/CallHistoryDB",
    "Library/Application Support/Google",
    "Library/Application Support/Firefox",
    "Library/Application Support/BraveSoftware",
    "Library/Application Support/Microsoft Edge",
};

/// The safety policy, in one pure function with no I/O:
///
///   * only paths strictly inside `$HOME` may ever be deleted, so the OS and
///     everything the system owns is out of reach by construction
///   * `$HOME` itself and its standard folders are never deleted
///   * credentials, keychains, mail, photos and browser profiles are never
///     deleted, even if a rule asks for them
///   * paths containing `.` or `..` components are rejected outright, so a
///     crafted entry can never walk out of the directory being emptied
///
/// Returns the reason when `abs_path` must not be deleted.
pub fn checkPath(home_raw: []const u8, abs_path: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, abs_path, "/");
    if (trimmed.len == 0) return "refusing to delete the filesystem root";
    if (!std.fs.path.isAbsolute(trimmed)) return "not an absolute path";
    if (hasDotComponent(trimmed)) return "path contains a '.' or '..' component";

    for (protected_paths) |blocked| {
        if (std.mem.eql(u8, trimmed, blocked)) return "refusing to delete a system location";
    }

    if (home_raw.len == 0) return "home directory is unknown";
    const home = std.mem.trimEnd(u8, home_raw, "/");

    if (std.mem.eql(u8, trimmed, home)) return "refusing to delete the home directory";
    if (isAncestorOf(trimmed, home)) return "refusing to delete a parent of the home directory";
    if (!scan.isInside(trimmed, home)) {
        return "outside the home directory - mac-cleaner never touches the OS";
    }

    const rel = std.mem.trimStart(u8, trimmed[home.len..], "/\\");
    if (rel.len == 0) return "refusing to delete the home directory";

    for (protected_home_exact) |blocked| {
        if (std.mem.eql(u8, rel, blocked)) return "refusing to delete a standard home folder";
    }
    for (protected_home_prefix) |blocked| {
        if (std.mem.eql(u8, rel, blocked)) return "refusing to delete a protected home folder";
        if (std.mem.startsWith(u8, rel, blocked) and rel.len > blocked.len and rel[blocked.len] == '/') {
            return "refusing to delete data inside a protected home folder";
        }
    }

    return null;
}

fn hasDotComponent(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return true;
    }
    return false;
}

fn isAncestorOf(candidate: []const u8, descendant: []const u8) bool {
    if (descendant.len <= candidate.len) return false;
    if (!std.mem.startsWith(u8, descendant, candidate)) return false;
    const next = descendant[candidate.len];
    return next == '/' or next == '\\';
}

/// Lexical check plus a symlink-resolved check. `abs_path` is not followed for
/// its final component, so a symlinked cache directory is still unlinked
/// safely, but a symlinked *parent* can never redirect the deletion somewhere
/// outside the home directory.
fn blockedReason(ctx: *ui.Ctx, abs_path: []const u8) ?[]const u8 {
    if (checkPath(ctx.home, abs_path)) |reason| return reason;

    const io = ctx.io;
    const real_home = std.Io.Dir.realPathFileAbsoluteAlloc(io, ctx.home, ctx.arena) catch
        return "cannot resolve the home directory";
    const real_path = std.Io.Dir.realPathFileAbsoluteAlloc(io, abs_path, ctx.arena) catch
        return "cannot resolve the real path";

    return checkPath(real_home, real_path);
}

fn removeTreeAt(ctx: *ui.Ctx, abs_path: []const u8) !void {
    const parent = std.fs.path.dirname(abs_path) orelse "/";
    const base = std.fs.path.basename(abs_path);
    // Never traverse a symlinked parent directory.
    var dir = try std.Io.Dir.openDirAbsolute(ctx.io, parent, .{ .follow_symlinks = false });
    defer dir.close(ctx.io);
    try dir.deleteTree(ctx.io, base);
}

fn removeFileAt(ctx: *ui.Ctx, abs_path: []const u8) !void {
    const parent = std.fs.path.dirname(abs_path) orelse "/";
    const base = std.fs.path.basename(abs_path);
    var dir = try std.Io.Dir.openDirAbsolute(ctx.io, parent, .{ .follow_symlinks = false });
    defer dir.close(ctx.io);
    try dir.deleteFile(ctx.io, base);
}

/// Deletes one path, never following a symlink out of the tree.
/// Returns false when the safety policy refused the path.
pub fn removePath(ctx: *ui.Ctx, abs_path: []const u8, mode: rules.Remove) !bool {
    if (checkPath(ctx.home, abs_path)) |reason| {
        if (ctx.verbose) ctx.note("  skipped {s}: {s}\n", .{ abs_path, reason });
        return false;
    }

    // Nothing to do, and nothing to resolve.
    const kind = measure.kindOf(ctx.io, abs_path) orelse return true;

    // A symlink is unlinked, never followed, so it cannot reach anything.
    // Emptying a symlinked directory is refused: the contents rule promises to
    // touch only the directory it names.
    if (kind == .sym_link) {
        if (mode == .contents) {
            if (ctx.verbose) ctx.note("  skipped {s}: refusing to empty a symlinked directory\n", .{abs_path});
            return false;
        }
        try removeFileAt(ctx, abs_path);
        return true;
    }

    if (blockedReason(ctx, abs_path)) |reason| {
        if (ctx.verbose) ctx.note("  skipped {s}: {s}\n", .{ abs_path, reason });
        return false;
    }

    switch (kind) {
        .file => try removeFileAt(ctx, abs_path),
        .directory => switch (mode) {
            .contents => {
                const children = try measure.listChildren(ctx.io, ctx.arena, abs_path);
                for (children) |child| {
                    _ = removePath(ctx, child, .tree) catch |err| {
                        if (ctx.verbose) ctx.note("  could not delete {s}: {s}\n", .{ child, @errorName(err) });
                    };
                }
            },
            else => try removeTreeAt(ctx, abs_path),
        },
        else => {},
    }

    return true;
}

pub const Plan = struct {
    items: []const scan.Result = &.{},
    bytes: u64 = 0,
    actionable: usize = 0,
    info_only: usize = 0,
};

/// Builds the deletion plan. System locations never enter it, whatever the
/// caller asks for: they are counted in `info_only` and reported instead.
pub fn buildPlan(arena: std.mem.Allocator, results: []const scan.Result, opts: Options) !Plan {
    var items: std.ArrayList(scan.Result) = .empty;
    var plan: Plan = .{};

    for (results) |result| {
        if (scan.contains(opts.exclude, result.rule.id)) continue;
        if (opts.only.len != 0) {
            if (!scan.contains(opts.only, result.rule.id)) continue;
        } else {
            if (@intFromEnum(result.rule.safety) > @intFromEnum(opts.level)) continue;
        }

        if (result.needs_root) {
            plan.info_only += 1;
            continue;
        }

        try items.append(arena, result);
        plan.bytes += result.bytes;
        if (result.paths.len != 0 or result.rule.kind == .command) plan.actionable += 1;
    }

    plan.items = try items.toOwnedSlice(arena);
    return plan;
}

pub fn run(ctx: *ui.Ctx, results: []const scan.Result, opts: Options) !void {
    const plan = try buildPlan(ctx.arena, results, opts);
    const info_only = plan.info_only;

    if (plan.actionable == 0) {
        ctx.note("nothing to delete at level '{s}'.\n", .{opts.level.label()});
        if (info_only != 0) {
            ctx.note("{d} system locations were skipped; mac-cleaner never deletes them.\n", .{info_only});
        }
        return;
    }

    if (ctx.json) {
        if (!opts.apply) {
            // Machine readable dry run: describe the plan, delete nothing.
            try report.renderJson(ctx, plan.items, .{ .heading = "Would delete (dry run)" });
            return;
        }
        try applyAll(ctx, plan.items, opts);
        return;
    }

    try report.renderScan(ctx, plan.items, .{
        .heading = if (opts.apply) "Plan" else "Would delete (dry run)",
    });

    if (!opts.apply) {
        var buf: [32]u8 = undefined;
        try ctx.out.print("\n", .{});
        try ctx.paint(ui.bold);
        try ctx.out.writeAll("  dry run");
        try ctx.reset();
        try ctx.out.print(" - nothing was deleted. ", .{});
        try ctx.out.writeAll(humanize.bytes(&buf, plan.bytes));
        try ctx.out.writeAll(" can be reclaimed with `mac-cleaner clean --apply`.\n");
        try ctx.paint(ui.dim);
        try ctx.out.writeAll("  add `--level safe` to only touch junk, or `--only <id>` for a single rule.\n");
        try ctx.out.writeAll("  only files inside your home folder are ever deleted; system locations are read-only here.\n");
        try ctx.reset();
        if (info_only != 0) {
            ctx.note("{d} system locations skipped: mac-cleaner never deletes them.\n", .{info_only});
        }
        return;
    }

    try applyAll(ctx, plan.items, opts);

    if (!ctx.json) {
        try ctx.out.print("\n", .{});
        try ui.indent(ctx, "only files inside your home folder were touched; system locations stay untouched");
        if (info_only != 0) ctx.note("{d} system locations skipped: mac-cleaner never deletes them.\n", .{info_only});
    }
}

fn applyAll(ctx: *ui.Ctx, plan: []const scan.Result, opts: Options) !void {
    _ = opts;

    var outcomes: std.ArrayList(Outcome) = .empty;
    var index: usize = 0;
    for (plan) |result| {
        if (result.rule.kind == .path and result.paths.len == 0) continue;
        if (result.rule.kind == .path and result.bytes == 0 and !ctx.verbose) continue;
        index += 1;
        ctx.status("deleting {d}/{d}  {s}", .{ index, plan.len, result.rule.title });

        var outcome: Outcome = .{
            .id = result.rule.id,
            .title = result.rule.title,
            .bytes = result.bytes,
            .status = .deleted,
        };

        if (result.needs_root) {
            outcome.status = .root_required;
            outcome.bytes = 0;
            outcome.detail = "system location - mac-cleaner never touches it";
            try outcomes.append(ctx.arena, outcome);
            continue;
        }

        switch (result.rule.kind) {
            .path => {
                var removed_any = false;
                var all_ok = true;
                for (result.paths) |path| {
                    const ok = removePath(ctx, path, result.rule.remove) catch |err| {
                        if (ctx.verbose) ctx.note("  failed {s}: {s}\n", .{ path, @errorName(err) });
                        all_ok = false;
                        continue;
                    };
                    if (ok) removed_any = true else all_ok = false;
                }
                outcome.status = if (!removed_any)
                    .skipped_protected
                else if (all_ok)
                    .deleted
                else
                    .partially_deleted;
                outcome.bytes = if (removed_any) result.bytes else 0;
            },
            .command => {
                const output = proc.run(ctx, result.rule.argv);
                if (output.not_found) {
                    outcome.status = .command_missing;
                    outcome.bytes = 0;
                    outcome.detail = try rules.commandLine(ctx.arena, result.rule);
                } else if (output.ok) {
                    outcome.status = .command_ran;
                    outcome.detail = std.mem.trim(u8, output.stdout, " \t\r\n");
                    if (outcome.detail.len > 120) outcome.detail = outcome.detail[0..120];
                } else {
                    outcome.status = .command_failed;
                    outcome.bytes = 0;
                    const stderr_text = std.mem.trim(u8, output.stderr, " \t\r\n");
                    outcome.detail = if (stderr_text.len != 0) stderr_text else "command failed";
                    if (outcome.detail.len > 160) outcome.detail = outcome.detail[0..160];
                }
            },
        }

        try outcomes.append(ctx.arena, outcome);
    }

    ctx.clearStatus();

    if (ctx.json) {
        try printJson(ctx, outcomes.items);
        return;
    }

    try printOutcomes(ctx, outcomes.items);
}

pub const Label = struct {
    text: []const u8,
    color: []const u8,
};

/// Width of the result column; `not installed` must fit.
const result_column: usize = 14;

fn statusLabel(status: Status) Label {
    return switch (status) {
        .deleted => .{ .text = "deleted", .color = ui.green },
        .partially_deleted => .{ .text = "partial", .color = ui.yellow },
        .failed => .{ .text = "failed", .color = ui.red },
        .skipped_protected => .{ .text = "skipped", .color = ui.yellow },
        .root_required => .{ .text = "info only", .color = ui.magenta },
        .command_ran => .{ .text = "ran", .color = ui.green },
        .command_failed => .{ .text = "failed", .color = ui.red },
        .command_missing => .{ .text = "not installed", .color = ui.dim },
    };
}

fn printOutcomes(ctx: *ui.Ctx, outcomes: []const Outcome) !void {
    var freed: u64 = 0;
    var failed: usize = 0;
    var root_needed: usize = 0;

    try ctx.paint(ui.dim);
    try humanize.writeAligned(ctx.out, "SIZE", ui.columns.size);
    try ctx.out.print("  ", .{});
    try humanize.writeLeftAligned(ctx.out, "RESULT", result_column);
    try ctx.out.print("  ITEM\n", .{});
    try ctx.reset();

    for (outcomes) |outcome| {
        const label = statusLabel(outcome.status);
        var buf: [32]u8 = undefined;

        try humanize.writeAligned(ctx.out, humanize.bytes(&buf, outcome.bytes), ui.columns.size);
        try ctx.out.print("  ", .{});
        try ctx.paint(label.color);
        try humanize.writeLeftAligned(ctx.out, label.text, result_column);
        try ctx.reset();
        try ctx.out.print("  {s}", .{outcome.title});
        if (outcome.detail.len != 0) {
            try ctx.out.print("  ", .{});
            try ctx.paint(ui.dim);
            try ctx.out.writeAll(outcome.detail);
            try ctx.reset();
        }
        try ctx.out.print("\n", .{});

        switch (outcome.status) {
            .deleted, .command_ran => freed += outcome.bytes,
            .partially_deleted => freed += outcome.bytes / 2,
            .root_required => root_needed += 1,
            .failed, .command_failed => failed += 1,
            else => {},
        }
    }

    var buf: [32]u8 = undefined;
    try ctx.out.print("\n", .{});
    try ui.ruler(ctx, 74);
    try ctx.paint(ui.bold);
    try humanize.writeAligned(ctx.out, humanize.bytes(&buf, freed), ui.columns.size);
    try ctx.reset();
    try ctx.out.print(" freed", .{});
    if (failed != 0) try ctx.out.print(", {d} failed", .{failed});
    if (root_needed != 0) try ctx.out.print(", {d} need sudo", .{root_needed});
    try ctx.out.print("\n", .{});

    if (root_needed != 0) {
        try ctx.paint(ui.dim);
        try ctx.out.writeAll("  'info only' entries are outside your home directory; mac-cleaner never deletes them.\n");
        try ctx.reset();
    }
}

fn printJson(ctx: *ui.Ctx, outcomes: []const Outcome) !void {
    try ctx.out.writeAll("{\n  \"results\": [");
    var first = true;
    var freed: u64 = 0;
    for (outcomes) |outcome| {
        try ctx.out.writeAll(if (first) "\n" else ",\n");
        first = false;
        try ctx.out.writeAll("    {\"id\": \"");
        try ctx.out.writeAll(outcome.id);
        try ctx.out.writeAll("\", \"status\": \"");
        try ctx.out.writeAll(@tagName(outcome.status));
        try ctx.out.print("\", \"bytes\": {d}}}", .{outcome.bytes});
        switch (outcome.status) {
            .deleted, .command_ran => freed += outcome.bytes,
            else => {},
        }
    }
    try ctx.out.writeAll(if (first) "],\n" else "\n  ],\n");
    try ctx.out.print("  \"freed_bytes\": {d}\n}}\n", .{freed});
}

test "nothing outside the home directory is ever deletable" {
    const home = "/Users/me";

    // system locations
    try std.testing.expect(checkPath(home, "/") != null);
    try std.testing.expect(checkPath(home, "/Users") != null);
    try std.testing.expect(checkPath(home, "/Library") != null);
    try std.testing.expect(checkPath(home, "/Library/Caches") != null);
    try std.testing.expect(checkPath(home, "/private/var/vm/sleepimage") != null);
    try std.testing.expect(checkPath(home, "/cores/crash.dump") != null);
    try std.testing.expect(checkPath(home, "/Users/Shared/Relocated Items/x") != null);
    try std.testing.expect(checkPath(home, "/Volumes/External/proj/node_modules") != null);

    // the home directory and its standard folders
    try std.testing.expect(checkPath(home, "/Users/me") != null);
    try std.testing.expect(checkPath(home, "/Users/me/Library") != null);
    try std.testing.expect(checkPath(home, "/Users/me/Documents") != null);
    try std.testing.expect(checkPath(home, "/Users/men/x") != null);
    try std.testing.expect(checkPath(home, "relative/path") != null);
    try std.testing.expect(checkPath(home, "") != null);

    // secrets and user data inside home
    try std.testing.expect(checkPath(home, "/Users/me/.ssh/id_rsa") != null);
    try std.testing.expect(checkPath(home, "/Users/me/Library/Keychains/login.keychain-db") != null);
    try std.testing.expect(checkPath(home, "/Users/me/Library/Mail/V10") != null);
    try std.testing.expect(checkPath(home, "/Users/me/Library/Group Containers/x/y") != null);
    try std.testing.expect(checkPath(home, "/Users/me/Library/Application Support/Google/Chrome") != null);
    try std.testing.expect(checkPath(home, "/Users/me/.config/gh/hosts.yml") != null);

    // things the tool is actually meant to clean
    try std.testing.expect(checkPath(home, "/Users/me/Library/Caches") == null);
    try std.testing.expect(checkPath(home, "/Users/me/Library/Caches/com.foo") == null);
    try std.testing.expect(checkPath(home, "/Users/me/.Trash") == null);
    try std.testing.expect(checkPath(home, "/Users/me/.Trash/old.dmg") == null);
    try std.testing.expect(checkPath(home, "/Users/me/Library/Developer/Xcode/DerivedData/App-abc") == null);
    try std.testing.expect(checkPath(home, "/Users/me/Library/Application Support/Code/Cache") == null);
    try std.testing.expect(checkPath(home, "/Users/me/code/app/node_modules") == null);
    try std.testing.expect(checkPath(home, "/Users/me/.npm/_cacache") == null);
    try std.testing.expect(checkPath(home, "/Users/me/Dropbox/.dropbox.cache") == null);
}

test "paths with dot components are always refused" {
    const home = "/Users/me";
    try std.testing.expect(checkPath(home, "/Users/me/Library/Caches/..") != null);
    try std.testing.expect(checkPath(home, "/Users/me/Library/Caches/../..") != null);
    try std.testing.expect(checkPath(home, "/Users/me/Library/Caches/../../../etc") != null);
    try std.testing.expect(checkPath(home, "/Users/me/./Documents") != null);
    try std.testing.expect(checkPath(home, "/Users/me/Library/Caches/.") != null);
    // a name that merely starts with dots is fine
    try std.testing.expect(checkPath(home, "/Users/me/Library/Caches/..foo") == null);
}

test "an unknown home directory refuses everything" {
    try std.testing.expect(checkPath("", "/Users/me/Library/Caches") != null);
    try std.testing.expect(checkPath("", "/tmp/x") != null);
}

/// Replaces `~` with `home` and every wildcard with a representative name, so
/// each rule can be checked against the safety policy without touching disk.
fn materialize(arena: std.mem.Allocator, home: []const u8, pattern: []const u8) ![]const u8 {
    const full = if (std.mem.startsWith(u8, pattern, "~/"))
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, pattern[2..] })
    else
        try arena.dupe(u8, pattern);

    var out: std.ArrayList(u8) = .empty;
    for (full) |ch| {
        if (ch == '*') {
            try out.appendSlice(arena, "example");
        } else {
            try out.append(arena, ch);
        }
    }
    return out.toOwnedSlice(arena);
}

test "every user rule points at a path the policy allows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/Users/tester";

    for (rules.rules) |rule| {
        for (rule.paths) |pattern| {
            const path = try materialize(arena, home, pattern);
            if (rule.needs_root) {
                // System locations must be refused, and must really be outside home.
                try std.testing.expect(!scan.isInside(path, home));
                try std.testing.expect(checkPath(home, path) != null);
            } else {
                if (checkPath(home, path)) |reason| {
                    std.debug.print("rule '{s}' targets {s}: {s}\n", .{ rule.id, path, reason });
                    return error.RuleTargetsProtectedPath;
                }
                try std.testing.expect(scan.isInside(path, home));
            }
        }
    }
}

test "the deletion plan never contains a system location" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const results = [_]scan.Result{
        .{
            .rule = .{ .id = "junk", .title = "junk", .group = .system, .safety = .safe },
            .paths = &.{"/Users/me/.Trash/x"},
            .bytes = 10,
        },
        .{
            .rule = .{ .id = "system", .title = "system", .group = .system, .safety = .safe, .needs_root = true },
            .paths = &.{"/Library/Caches"},
            .bytes = 999,
            .needs_root = true,
        },
        .{
            .rule = .{ .id = "big", .title = "big", .group = .containers, .safety = .risky },
            .paths = &.{"/Users/me/Library/Containers/com.docker.docker/Data"},
            .bytes = 50,
        },
    };

    const all = try buildPlan(arena, &results, .{ .level = .risky });
    try std.testing.expectEqual(@as(usize, 2), all.items.len);
    try std.testing.expectEqual(@as(usize, 1), all.info_only);
    try std.testing.expectEqual(@as(u64, 60), all.bytes);
    for (all.items) |item| try std.testing.expect(!item.needs_root);

    // Even asking for it by name cannot put a system location in the plan.
    const targeted = try buildPlan(arena, &results, .{ .level = .risky, .only = &.{"system"} });
    try std.testing.expectEqual(@as(usize, 0), targeted.items.len);
    try std.testing.expectEqual(@as(usize, 0), targeted.actionable);
    try std.testing.expectEqual(@as(usize, 1), targeted.info_only);

    // Level filtering still applies.
    const safe_only = try buildPlan(arena, &results, .{ .level = .safe });
    try std.testing.expectEqual(@as(usize, 1), safe_only.items.len);
    try std.testing.expectEqualStrings("junk", safe_only.items[0].rule.id);
}

fn testJoin(arena: std.mem.Allocator, base: []const u8, rest: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ base, rest });
}

test "removePath deletes junk and keeps protected data" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, arena);
    const home = try std.fmt.allocPrint(arena, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path[0..] });

    // A miniature Mac home directory.
    try tmp.dir.createDirPath(io, "Library/Caches/com.foo");
    try tmp.dir.writeFile(io, .{ .sub_path = "Library/Caches/com.foo/x.db", .data = "junk" });
    try tmp.dir.createDirPath(io, ".npm/_cacache");
    try tmp.dir.writeFile(io, .{ .sub_path = ".npm/_cacache/y.bin", .data = "junk" });
    try tmp.dir.createDirPath(io, ".Trash");
    try tmp.dir.writeFile(io, .{ .sub_path = ".Trash/old.iso", .data = "junk" });
    try tmp.dir.createDirPath(io, "Documents");
    try tmp.dir.writeFile(io, .{ .sub_path = "Documents/thesis.docx", .data = "important" });
    try tmp.dir.createDirPath(io, ".ssh");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ssh/id_rsa", .data = "secret" });
    try tmp.dir.createDirPath(io, "Library/Keychains");
    try tmp.dir.writeFile(io, .{ .sub_path = "Library/Keychains/login.keychain-db", .data = "secret" });
    try tmp.dir.createDirPath(io, "Library/Application Support/Google/Chrome");
    try tmp.dir.writeFile(io, .{ .sub_path = "Library/Application Support/Google/Chrome/Login Data", .data = "secret" });
    try tmp.dir.createDirPath(io, "code/proj");
    try tmp.dir.writeFile(io, .{ .sub_path = "code/proj/main.zig", .data = "source" });

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var err_writer = std.Io.Writer.fixed(&out_buf);
    var ctx: ui.Ctx = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = io,
        .out = &out_writer,
        .err = &err_writer,
        .home = home,
        .color = false,
    };

    // Junk is deleted.
    try std.testing.expect(try removePath(&ctx, try testJoin(arena, home, "Library/Caches"), .contents));
    try std.testing.expect(try removePath(&ctx, try testJoin(arena, home, ".npm/_cacache"), .tree));
    try std.testing.expect(try removePath(&ctx, try testJoin(arena, home, ".Trash"), .contents));

    // Important data is refused, at every level of the hierarchy.
    try std.testing.expect(!try removePath(&ctx, try testJoin(arena, home, "Documents"), .contents));
    try std.testing.expect(!try removePath(&ctx, try testJoin(arena, home, ".ssh"), .tree));
    try std.testing.expect(!try removePath(&ctx, try testJoin(arena, home, "Library"), .contents));
    try std.testing.expect(!try removePath(&ctx, try testJoin(arena, home, "Library/Keychains/login.keychain-db"), .file));
    try std.testing.expect(!try removePath(&ctx, try testJoin(arena, home, "Library/Application Support/Google/Chrome"), .tree));
    try std.testing.expect(!try removePath(&ctx, try testJoin(arena, home, "code"), .tree));
    try std.testing.expect(!try removePath(&ctx, "/Library/Caches", .contents));
    try std.testing.expect(!try removePath(&ctx, try testJoin(arena, home, "Library/Caches/../../Documents"), .tree));

    // Verified on disk.
    try std.testing.expect(measure.exists(io, try testJoin(arena, home, "Library/Caches")));
    try std.testing.expect(!measure.exists(io, try testJoin(arena, home, "Library/Caches/com.foo")));
    try std.testing.expect(!measure.exists(io, try testJoin(arena, home, ".npm/_cacache")));
    try std.testing.expect(measure.exists(io, try testJoin(arena, home, ".Trash")));
    try std.testing.expect(!measure.exists(io, try testJoin(arena, home, ".Trash/old.iso")));
    try std.testing.expect(measure.exists(io, try testJoin(arena, home, "Documents/thesis.docx")));
    try std.testing.expect(measure.exists(io, try testJoin(arena, home, ".ssh/id_rsa")));
    try std.testing.expect(measure.exists(io, try testJoin(arena, home, "Library/Keychains/login.keychain-db")));
    try std.testing.expect(measure.exists(io, try testJoin(arena, home, "Library/Application Support/Google/Chrome/Login Data")));
    try std.testing.expect(measure.exists(io, try testJoin(arena, home, "code/proj/main.zig")));
}

test "a symlinked parent cannot redirect a deletion" {
    const io = std.testing.io;
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, arena);
    const home = try std.fmt.allocPrint(arena, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path[0..] });

    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/precious.txt", .data = "keep me" });
    try tmp.dir.createDirPath(io, "Library");
    // ~/Library/Caches is a symlink to a directory outside the cache area.
    const target = try testJoin(arena, home, "outside");
    try tmp.dir.symLink(io, target, "Library/Caches", .{ .is_directory = true });

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var ctx: ui.Ctx = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = io,
        .out = &out_writer,
        .err = &out_writer,
        .home = home,
        .color = false,
    };

    // Refused: a contents rule must never empty a symlinked directory.
    try std.testing.expect(!try removePath(&ctx, try testJoin(arena, home, "Library/Caches"), .contents));
    try std.testing.expect(measure.exists(io, try testJoin(arena, home, "outside/precious.txt")));
    try std.testing.expect(measure.exists(io, try testJoin(arena, home, "Library/Caches")));
}

test "a symlinked leaf is unlinked rather than followed" {
    const io = std.testing.io;
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, arena);
    const home = try std.fmt.allocPrint(arena, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path[0..] });

    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/precious.txt", .data = "keep me" });
    try tmp.dir.createDirPath(io, "Library/Caches");
    const target = try testJoin(arena, home, "outside");
    try tmp.dir.symLink(io, target, "Library/Caches/link", .{ .is_directory = true });

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var ctx: ui.Ctx = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = io,
        .out = &out_writer,
        .err = &out_writer,
        .home = home,
        .color = false,
    };

    // The link goes, the directory it points at stays.
    try std.testing.expect(try removePath(&ctx, try testJoin(arena, home, "Library/Caches/link"), .tree));
    try std.testing.expect(!measure.exists(io, try testJoin(arena, home, "Library/Caches/link")));
    try std.testing.expect(measure.exists(io, try testJoin(arena, home, "outside/precious.txt")));
}

test "isAncestorOf" {
    try std.testing.expect(isAncestorOf("/Users", "/Users/me"));
    try std.testing.expect(!isAncestorOf("/Users/me", "/Users/me"));
    try std.testing.expect(!isAncestorOf("/Users/me", "/Users/men"));
}
