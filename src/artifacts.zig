//! Finds per-project build output (node_modules, target, .zig-cache, ...)
//! anywhere under your project folders.

const std = @import("std");
const clean = @import("clean.zig");
const humanize = @import("humanize.zig");
const measure = @import("measure.zig");
const report = @import("report.zig");
const ui = @import("ui.zig");

pub const Pattern = struct {
    name: []const u8,
    /// At least one of these files must exist next to the directory. Keeps
    /// things like `target` or `_build` from matching unrelated folders.
    markers: []const []const u8 = &.{},
    /// Only used with `--include`.
    opt_in: bool = false,
};

pub const patterns = [_]Pattern{
    .{ .name = "node_modules" },
    .{ .name = "__pycache__" },
    .{ .name = ".pytest_cache" },
    .{ .name = ".mypy_cache" },
    .{ .name = ".ruff_cache" },
    .{ .name = ".tox" },
    .{ .name = ".nox" },
    .{ .name = ".zig-cache" },
    .{ .name = "zig-out" },
    .{ .name = ".turbo" },
    .{ .name = ".parcel-cache" },
    .{ .name = ".next" },
    .{ .name = ".nuxt" },
    .{ .name = ".svelte-kit" },
    .{ .name = ".angular" },
    .{ .name = ".astro" },
    .{ .name = ".terraform" },
    .{ .name = ".dart_tool" },
    .{ .name = ".gradle" },
    .{ .name = "Pods" },
    .{ .name = ".stack-work" },
    .{ .name = ".elixir_ls" },
    .{ .name = "target", .markers = &.{ "Cargo.toml", "Cargo.lock" } },
    .{ .name = ".build", .markers = &.{"Package.swift"} },
    .{ .name = "deps", .markers = &.{"mix.exs"} },
    .{ .name = "_build", .markers = &.{"mix.exs"} },
    .{ .name = ".venv", .markers = &.{ "pyproject.toml", "requirements.txt", "setup.py", "Pipfile" } },
    .{ .name = "venv", .markers = &.{ "pyproject.toml", "requirements.txt", "setup.py", "Pipfile" } },
    // Opt in only: frequent false positives in hand written project layouts.
    .{ .name = "dist", .opt_in = true },
    .{ .name = "build", .opt_in = true },
    .{ .name = "vendor", .opt_in = true },
    .{ .name = "bin", .opt_in = true },
    .{ .name = "obj", .opt_in = true },
};

/// Never descended into. These hold toolchains, not project output.
const skip_names = [_][]const u8{
    "Library",   ".git",                         ".hg",            ".svn",
    ".Trash",    "Applications",                 "node_modules",   ".rustup",
    ".cargo",    ".npm",                         ".nvm",           ".pyenv",
    ".rbenv",    ".bun",                         ".deno",          ".local",
    ".cache",    "go",                           ".m2",            ".ivy2",
    ".sbt",      ".android",                     ".pub-cache",     ".gem",
    ".bundle",   ".conda",                       "anaconda3",      "miniconda3",
    ".docker",   ".colima",                      ".lima",          ".minikube",
    ".kube",     ".vagrant.d",                   "VirtualBox VMs", ".terraform.d",
    ".vmodules", ".opam",                        ".conan2",        ".asdf",
    ".sdkman",   ".julia",                       ".hex",           ".mix",
    ".stack",    ".cabal",                       ".nuget",         ".oh-my-zsh",
    ".vscode",   ".vscode-server",               "Pictures",       "Movies",
    "Music",     "Photos Library.photoslibrary", ".npm-global",    ".vscode-insiders",
    "Trash",
};

pub const Found = struct {
    path: []const u8,
    name: []const u8,
    totals: measure.Totals,
};

/// Width of the artifact name column; `node_modules` must fit.
const kind_column: usize = 14;

pub const Options = struct {
    roots: []const []const u8 = &.{},
    depth: usize = 8,
    /// Include `dist`, `build`, `vendor`, `bin` and `obj`.
    include_extra: bool = false,
    /// Extra directory names from `--include`.
    extra: []const []const u8 = &.{},
    min_bytes: u64 = 0,
};

fn isSkipped(name: []const u8) bool {
    for (skip_names) |skipped| {
        if (std.mem.eql(u8, name, skipped)) return true;
    }
    return false;
}

pub fn isKnownName(name: []const u8, opts: Options) bool {
    for (patterns) |pattern| {
        if (!std.mem.eql(u8, name, pattern.name)) continue;
        if (pattern.opt_in and !opts.include_extra) continue;
        return true;
    }
    for (opts.extra) |extra| {
        if (std.mem.eql(u8, name, extra)) return true;
    }
    return false;
}

fn matchPattern(
    ctx: *ui.Ctx,
    entry: std.Io.Dir.Walker.Entry,
    opts: Options,
) bool {
    for (opts.extra) |extra| {
        if (std.mem.eql(u8, entry.basename, extra)) return true;
    }
    for (patterns) |pattern| {
        if (!std.mem.eql(u8, entry.basename, pattern.name)) continue;
        if (pattern.opt_in and !opts.include_extra) continue;
        if (pattern.markers.len == 0) return true;
        for (pattern.markers) |marker| {
            _ = entry.dir.statFile(ctx.io, marker, .{}) catch continue;
            return true;
        }
    }
    return false;
}

/// Project roots to search when the user does not pass `--root`.
pub fn defaultRoots(ctx: *ui.Ctx) ![]const []const u8 {
    const candidates = [_][]const u8{
        "code",             "src",     "dev",       "Developer",
        "projects",         "repos",   "work",      "git",
        "Documents/GitHub", "Desktop", "Documents",
    };

    var found: std.ArrayList([]const u8) = .empty;
    for (candidates) |candidate| {
        const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ ctx.home, candidate });
        if (!measure.exists(ctx.io, path)) continue;
        try found.append(ctx.arena, path);
    }

    if (found.items.len == 0) {
        try found.append(ctx.arena, try ctx.arena.dupe(u8, ctx.home));
    }
    return found.toOwnedSlice(ctx.arena);
}

pub fn find(ctx: *ui.Ctx, opts: Options) ![]Found {
    var out: std.ArrayList(Found) = .empty;

    const roots = if (opts.roots.len != 0) opts.roots else try defaultRoots(ctx);
    for (roots) |root| {
        ctx.status("scanning {s}", .{root});
        scanRoot(ctx, root, opts, &out) catch |err| {
            if (ctx.verbose) ctx.note("  cannot scan {s}: {s}\n", .{ root, @errorName(err) });
        };
    }
    ctx.clearStatus();

    const owned = try out.toOwnedSlice(ctx.arena);
    std.sort.heap(Found, owned, {}, struct {
        fn lessThan(_: void, a: Found, b: Found) bool {
            return a.totals.bytes > b.totals.bytes;
        }
    }.lessThan);
    return owned;
}

/// True when the directory contains a git repository (or submodule) at a
/// shallow depth. Such a directory is real user data, not disposable build
/// output, so it is never deleted.
fn containsRepo(ctx: *ui.Ctx, abs_path: []const u8) bool {
    const max_depth: usize = 4;

    var dir = std.Io.Dir.openDirAbsolute(ctx.io, abs_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return false;
    defer dir.close(ctx.io);

    var walker = dir.walkSelectively(ctx.gpa) catch return false;
    defer walker.deinit();

    while (true) {
        const maybe_entry = walker.next(ctx.io) catch |err| switch (err) {
            error.OutOfMemory => return false,
            else => continue,
        };
        const entry = maybe_entry orelse break;

        if (std.mem.eql(u8, entry.basename, ".git")) return true;
        if (entry.kind != .directory) continue;

        const depth = 1 + std.mem.count(u8, entry.path, "/") + std.mem.count(u8, entry.path, "\\");
        if (depth < max_depth) walker.enter(ctx.io, entry) catch {};
    }
    return false;
}

fn scanRoot(ctx: *ui.Ctx, root: []const u8, opts: Options, out: *std.ArrayList(Found)) !void {
    var dir = try std.Io.Dir.openDirAbsolute(ctx.io, root, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer dir.close(ctx.io);

    var walker = try dir.walkSelectively(ctx.gpa);
    defer walker.deinit();

    while (true) {
        const maybe_entry = walker.next(ctx.io) catch |err| switch (err) {
            error.OutOfMemory => return,
            else => continue,
        };
        const entry = maybe_entry orelse break;

        if (entry.kind != .directory) continue;

        const name = entry.basename;

        // Artifact folders are measured and never descended into, so a nested
        // node_modules cannot be counted twice.
        if (matchPattern(ctx, entry, opts)) {
            const abs = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ root, entry.path });
            if (containsRepo(ctx, abs)) {
                if (ctx.verbose) ctx.note("  skipping {s}: it is a git repository\n", .{abs});
                continue;
            }
            const totals = measure.measureTree(ctx.io, ctx.gpa, abs);
            if (totals.bytes >= opts.min_bytes) {
                try out.append(ctx.arena, .{
                    .path = abs,
                    .name = try ctx.arena.dupe(u8, name),
                    .totals = totals,
                });
            }
            continue;
        }

        if (isSkipped(name)) continue;

        const depth = std.mem.count(u8, entry.path, "/") + 1;
        if (depth >= opts.depth) continue;
        walker.enter(ctx.io, entry) catch {};
    }
}

pub fn totalOf(found: []const Found) u64 {
    var total: u64 = 0;
    for (found) |item| total += item.totals.bytes;
    return total;
}

pub fn filesOf(found: []const Found) u64 {
    var total: u64 = 0;
    for (found) |item| total += item.totals.files;
    return total;
}

/// Writes the elements of the artifacts array, without the surrounding
/// brackets.
pub fn writeJsonArtifacts(ctx: *ui.Ctx, found: []const Found) !void {
    var first = true;
    for (found) |item| {
        try ctx.out.writeAll(if (first) "\n" else ",\n");
        first = false;
        try ctx.out.writeAll("    {\"path\": ");
        try report.writeJsonString(ctx, item.path);
        try ctx.out.writeAll(", \"name\": ");
        try report.writeJsonString(ctx, item.name);
        try ctx.out.print(", \"bytes\": {d}, \"files\": {d}}}", .{ item.totals.bytes, item.totals.files });
    }
    if (!first) try ctx.out.writeAll("\n  ");
}

pub fn render(ctx: *ui.Ctx, found: []const Found) !void {
    var total: u64 = 0;
    var files: u64 = 0;
    const now = ui.nowNs(ctx.io);

    if (ctx.json) {
        try ctx.out.writeAll("{\n  \"artifacts\": [");
        try writeJsonArtifacts(ctx, found);
        try ctx.out.print("],\n  \"total_bytes\": {d}, \"total_files\": {d}\n}}\n", .{ totalOf(found), filesOf(found) });
        return;
    }

    try ui.title(ctx, "Project build artifacts");

    try ctx.paint(ui.dim);
    try humanize.writeAligned(ctx.out, "SIZE", ui.columns.size);
    try ctx.out.print("  ", .{});
    try humanize.writeLeftAligned(ctx.out, "AGE", ui.columns.safety);
    try ctx.out.print("  ", .{});
    try humanize.writeLeftAligned(ctx.out, "KIND", kind_column);
    try ctx.out.print("  PATH\n", .{});
    try ctx.reset();

    for (found) |item| {
        var size_buf: [32]u8 = undefined;
        var age_buf: [32]u8 = undefined;
        const age = humanize.ageDays(now, item.totals.newest_mtime_ns);
        const age_text = std.fmt.bufPrint(&age_buf, "{d}d ago", .{age}) catch "";

        try humanize.writeAligned(ctx.out, humanize.bytes(&size_buf, item.totals.bytes), ui.columns.size);
        try ctx.out.print("  ", .{});
        try ctx.paint(ui.dim);
        try humanize.writeLeftAligned(ctx.out, age_text, ui.columns.safety);
        try ctx.reset();
        try ctx.out.print("  ", .{});
        try ctx.paint(ui.cyan);
        try humanize.writeLeftAligned(ctx.out, item.name, kind_column);
        try ctx.reset();
        try ctx.out.print("  {s}\n", .{item.path});

        total += item.totals.bytes;
        files += item.totals.files;
    }

    if (found.len == 0) {
        try ctx.paint(ui.dim);
        try ctx.out.writeAll("  no build artifacts found.\n");
        try ctx.reset();
        return;
    }

    var buf: [32]u8 = undefined;
    var file_buf: [32]u8 = undefined;
    try ctx.out.print("\n", .{});
    try ui.ruler(ctx, 74);
    try ctx.paint(ui.bold);
    try humanize.writeAligned(ctx.out, humanize.bytes(&buf, total), ui.columns.size);
    try ctx.reset();
    try ctx.out.print("  in {d} directories, {s}\n", .{ found.len, humanize.files(&file_buf, files) });
}

/// Deletes the given artifacts, refusing anything that is not a known pattern.
pub fn remove(ctx: *ui.Ctx, found: []const Found, opts: Options) !void {
    var freed: u64 = 0;
    var failed: usize = 0;
    var index: usize = 0;

    for (found) |item| {
        index += 1;
        ctx.status("deleting {d}/{d}  {s}", .{ index, found.len, item.path });

        if (!isKnownName(item.name, opts)) {
            ctx.note("skipping {s}: not a known artifact directory\n", .{item.path});
            continue;
        }
        if (containsRepo(ctx, item.path)) {
            ctx.note("skipping {s}: it is a git repository\n", .{item.path});
            continue;
        }

        const removed = clean.removePath(ctx, item.path, .tree) catch |err| {
            if (ctx.verbose) ctx.note("  failed {s}: {s}\n", .{ item.path, @errorName(err) });
            failed += 1;
            continue;
        };
        if (removed) {
            freed += item.totals.bytes;
        } else {
            ctx.note("skipped {s}: protected location\n", .{item.path});
        }
    }

    ctx.clearStatus();

    var buf: [32]u8 = undefined;
    try ctx.out.print("\n", .{});
    try ui.ruler(ctx, 74);
    try ctx.paint(ui.bold);
    try humanize.writeAligned(ctx.out, humanize.bytes(&buf, freed), ui.columns.size);
    try ctx.reset();
    try ctx.out.print("  freed", .{});
    if (failed != 0) try ctx.out.print(", {d} failed", .{failed});
    try ctx.out.print("\n", .{});
}

test "skip list covers toolchain folders" {
    try std.testing.expect(isSkipped("Library"));
    try std.testing.expect(isSkipped(".cargo"));
    // node_modules is skipped once matched, so a nested one is not walked twice.
    try std.testing.expect(isSkipped("node_modules"));
    try std.testing.expect(!isSkipped("target"));
}

test "opt-in patterns need include_extra" {
    const opts: Options = .{};
    try std.testing.expect(isKnownName("node_modules", opts));
    try std.testing.expect(!isKnownName("dist", opts));
    try std.testing.expect(isKnownName("dist", .{ .include_extra = true }));
    try std.testing.expect(isKnownName("custom-out", .{ .extra = &.{"custom-out"} }));
}

test "artifact pattern names can never target protected data" {
    const home = "/Users/tester";
    for (patterns) |pattern| {
        const path = std.fmt.allocPrint(std.testing.allocator, "{s}/code/project/{s}", .{ home, pattern.name }) catch unreachable;
        defer std.testing.allocator.free(path);
        if (clean.checkPath(home, path)) |reason| {
            std.debug.print("artifact pattern '{s}': {s}\n", .{ pattern.name, reason });
            return error.ArtifactPatternIsProtected;
        }
    }
}

test "containsRepo detects nested repositories" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "junk/node_modules/pkg");
    try tmp.dir.createDirPath(io, "repo/vendor/real/.git");
    try tmp.dir.createDirPath(io, "plain/target");

    const cwd = try std.process.currentPathAlloc(io, arena);
    const root = try std.fmt.allocPrint(arena, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path[0..] });

    var out_buf: [1024]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var ctx: ui.Ctx = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = io,
        .out = &out_writer,
        .err = &out_writer,
        .home = root,
    };

    const nm = try std.fmt.allocPrint(arena, "{s}/junk/node_modules", .{root});
    const vendor = try std.fmt.allocPrint(arena, "{s}/repo/vendor", .{root});
    const target = try std.fmt.allocPrint(arena, "{s}/plain/target", .{root});

    try std.testing.expect(!containsRepo(&ctx, nm));
    try std.testing.expect(containsRepo(&ctx, vendor));
    try std.testing.expect(!containsRepo(&ctx, target));
}

test "pattern names are unique" {
    for (patterns, 0..) |pattern, i| {
        for (patterns[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, pattern.name, other.name));
        }
    }
}
