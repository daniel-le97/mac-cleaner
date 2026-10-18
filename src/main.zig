const std = @import("std");

const artifacts = @import("artifacts.zig");
const big = @import("big.zig");
const clean = @import("clean.zig");
const cli = @import("cli.zig");
const doctor = @import("doctor.zig");
const humanize = @import("humanize.zig");
const report = @import("report.zig");
const rules = @import("rules.zig");
const scan = @import("scan.zig");
const ui = @import("ui.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buffer: [16 * 1024]u8 = undefined;
    var out_file_writer: std.Io.File.Writer = .init(.stdout(), io, &out_buffer);
    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file_writer: std.Io.File.Writer = .init(.stderr(), io, &err_buffer);

    run(init, &out_file_writer.interface, &err_file_writer.interface) catch |err| {
        err_file_writer.interface.print("mac-cleaner: {s}\n", .{@errorName(err)}) catch {};
        err_file_writer.interface.flush() catch {};
        out_file_writer.interface.flush() catch {};
        std.process.exit(1);
    };

    out_file_writer.interface.flush() catch {};
    err_file_writer.interface.flush() catch {};
}

fn parseErrorMessage(err: cli.ParseError) []const u8 {
    return switch (err) {
        error.MissingValue => "that option needs a value",
        error.UnknownFlag => "unknown option",
        error.UnknownCommand => "unknown command, run `mac-cleaner help`",
        error.InvalidLevel => "level must be safe, recreatable or risky",
        error.InvalidGroup => "unknown group, run `mac-cleaner list` to see them",
        error.InvalidNumber => "expected a number",
        error.InvalidSize => "expected a size such as 500M",
        error.OutOfMemory => "out of memory",
    };
}

fn run(init: std.process.Init, out: *std.Io.Writer, err: *std.Io.Writer) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const home = init.environ_map.get("HOME") orelse
        init.environ_map.get("USERPROFILE") orelse "";

    const opts = cli.parse(arena, argv) catch |parse_err| {
        try err.print("mac-cleaner: {s}\n\n{s}", .{ parseErrorMessage(parse_err), cli.help_text });
        return;
    };

    if (opts.version) {
        try out.print("mac-cleaner {s}\n", .{cli.version});
        return;
    }

    if (opts.command == .help) {
        try out.writeAll(cli.help_text);
        return;
    }

    const no_color = init.environ_map.get("NO_COLOR") != null;
    const force_color = init.environ_map.get("CLICOLOR_FORCE") != null;
    const terminal = std.Io.Terminal.Mode.detect(io, .stdout(), no_color, force_color) catch .no_color;
    const is_tty = switch (terminal) {
        .no_color => false,
        else => true,
    };

    var ctx: ui.Ctx = .{
        .gpa = init.gpa,
        .arena = arena,
        .io = io,
        .out = out,
        .err = err,
        .home = home,
        .color = opts.color orelse is_tty,
        .json = opts.json,
        .verbose = opts.verbose,
        .quiet = opts.quiet,
        .show_paths = opts.show_paths,
        .tty = is_tty,
        .progress = is_tty and !opts.json and !opts.quiet,
    };

    if (home.len == 0 and opts.command != .doctor) {
        try err.writeAll("mac-cleaner: cannot determine your home directory (HOME is unset).\n");
        return;
    }

    switch (opts.command) {
        .help => unreachable,
        .audit => try runAudit(&ctx, opts),
        .scan => try runScan(&ctx, opts),
        .clean => try runClean(&ctx, opts),
        .artifacts => try runArtifacts(&ctx, opts),
        .big => try runBig(&ctx, opts),
        .du => try runDu(&ctx, opts),
        .doctor => try runDoctor(&ctx, opts),
        .list => try listRules(&ctx),
    }
}

/// Read-only sweep: disk summary, every rule, and every project artifact.
/// There is no deletion code on this path.
fn runAudit(ctx: *ui.Ctx, opts: cli.Options) !void {
    if (opts.apply_ignored and !ctx.json) {
        ctx.note("audit never deletes anything: ignoring --apply\n", .{});
    }

    const results = try scan.run(ctx, .{
        .level = opts.level,
        .group = opts.group,
        .only = opts.only,
        .exclude = opts.exclude,
    });

    const find_opts: artifacts.Options = .{
        .roots = opts.roots,
        .depth = opts.depth,
        .include_extra = opts.include_extra,
        .extra = opts.extra,
        .min_bytes = opts.min_bytes,
    };
    const found = try artifacts.find(ctx, find_opts);

    if (ctx.json) return renderAuditJson(ctx, opts, results, found);

    try ui.title(ctx, "Audit (read only)");
    try ui.indent(ctx, "nothing in this report deletes anything");

    const info = doctor.disk(ctx);
    if (info.ok) {
        var total_buf: [32]u8 = undefined;
        var used_buf: [32]u8 = undefined;
        var avail_buf: [32]u8 = undefined;
        try ctx.out.print("  ", .{});
        try ctx.paint(ui.dim);
        try ctx.out.writeAll("disk ");
        try ctx.reset();
        try ctx.out.print("{s} of {s} used, ", .{
            humanize.bytes(&used_buf, info.used),
            humanize.bytes(&total_buf, info.total),
        });
        try ctx.paint(if (info.available < 25 << 30) ui.red else ui.green);
        try ctx.out.writeAll(humanize.bytes(&avail_buf, info.available));
        try ctx.reset();
        try ctx.out.print(" available ({d}% used)\n", .{info.usedPercent()});
    }

    const snapshots = try doctor.localSnapshots(ctx);
    if (snapshots.len != 0) {
        try ctx.out.print("  Time Machine local snapshots: {d}\n", .{snapshots.len});
    }

    try report.renderScan(ctx, results, .{
        .heading = "Known cleanup locations",
        .show_empty = opts.only.len != 0,
    });

    try artifacts.render(ctx, found);

    const rules_bytes = scan.totals(results).total;
    const artifact_bytes = artifacts.totalOf(found);
    const grand_total = rules_bytes +| artifact_bytes;

    var buf: [32]u8 = undefined;
    var artifact_buf: [32]u8 = undefined;
    try ctx.out.print("\n", .{});
    try ui.ruler(ctx, 74);
    try ctx.paint(ui.bold);
    try humanize.writeAligned(ctx.out, humanize.bytes(&buf, grand_total), ui.columns.size);
    try ctx.reset();
    try ctx.out.writeAll("  reclaimable in total\n");
    try ui.indent(ctx, try std.fmt.allocPrint(ctx.arena, "known locations {s} + project build output {s}", .{
        humanize.bytes(&buf, rules_bytes),
        humanize.bytes(&artifact_buf, artifact_bytes),
    }));
    try ui.indent(ctx, "for everything else: `mac-cleaner du ~` and `mac-cleaner big ~`");
    try ui.indent(ctx, "to act: `mac-cleaner clean` to review a plan, then `mac-cleaner clean --level safe --apply`");
}

fn renderAuditJson(ctx: *ui.Ctx, opts: cli.Options, results: []const scan.Result, found: []const artifacts.Found) !void {
    const t = scan.totals(results);
    const artifact_bytes = artifacts.totalOf(found);
    const info = doctor.disk(ctx);

    try ctx.out.writeAll("{\n  \"generated_by\": \"mac-cleaner\",\n  \"read_only\": true,\n");
    try ctx.out.print(
        "  \"disk\": {{\"total_bytes\": {d}, \"used_bytes\": {d}, \"available_bytes\": {d}}},\n",
        .{ info.total, info.used, info.available },
    );
    try ctx.out.print(
        "  \"rules\": {{\"total_bytes\": {d}, \"safe_bytes\": {d}, \"recreatable_bytes\": {d}, \"risky_bytes\": {d}, \"items\": [",
        .{ t.total, t.safe, t.recreatable, t.risky },
    );
    try report.writeJsonItems(ctx, results, opts.only.len != 0);
    try ctx.out.writeAll("]},\n");
    try ctx.out.print("  \"artifacts\": {{\"total_bytes\": {d}, \"items\": [", .{artifact_bytes});
    try artifacts.writeJsonArtifacts(ctx, found);
    try ctx.out.writeAll("]},\n");
    try ctx.out.print("  \"reclaimable_bytes\": {d}\n}}\n", .{t.total +| artifact_bytes});
}

fn runScan(ctx: *ui.Ctx, opts: cli.Options) !void {
    const results = try scan.run(ctx, .{
        .level = opts.level,
        .group = opts.group,
        .only = opts.only,
        .exclude = opts.exclude,
    });

    try report.renderScan(ctx, results, .{
        .heading = "Cleanup scan",
        .show_empty = opts.only.len != 0,
    });

    if (!ctx.json) {
        try doctor.printDiskLine(ctx);
        try ctx.out.print("\n", .{});
        try ui.indent(ctx, "read only: scan measures, it never deletes anything");
        try ui.indent(ctx, "to act: `mac-cleaner clean` to review, then `mac-cleaner clean --level safe --apply`");
        if (ctx.verbose) {
            try ctx.out.print("\n", .{});
            for (doctor.advice) |line| try ui.indent(ctx, line);
        }
    }
}
fn runClean(ctx: *ui.Ctx, opts: cli.Options) !void {
    const results = try scan.run(ctx, .{
        .level = opts.level,
        .group = opts.group,
        .only = opts.only,
        .exclude = opts.exclude,
    });

    try clean.run(ctx, results, .{
        .level = opts.level,
        .only = opts.only,
        .exclude = opts.exclude,
        .apply = opts.apply,
    });
}

fn runArtifacts(ctx: *ui.Ctx, opts: cli.Options) !void {
    const find_opts: artifacts.Options = .{
        .roots = opts.roots,
        .depth = opts.depth,
        .include_extra = opts.include_extra,
        .extra = opts.extra,
        .min_bytes = opts.min_bytes,
    };

    const found = try artifacts.find(ctx, find_opts);
    try artifacts.render(ctx, found);

    if (opts.apply and !ctx.json and found.len != 0) {
        try ctx.out.print("\n", .{});
        try ctx.paint(ui.yellow);
        try ctx.out.writeAll("  deleting build output; `install` or `build` brings it back\n");
        try ctx.reset();
        try artifacts.remove(ctx, found, find_opts);
    } else if (!opts.apply and !ctx.json) {
        try ctx.out.print("\n", .{});
        try ui.indent(ctx, "read only: nothing was deleted. add `--apply` to remove these directories");
    }
}

fn runBig(ctx: *ui.Ctx, opts: cli.Options) !void {
    const root = if (opts.paths.len != 0) opts.paths[0] else ctx.home;
    const entries = try big.topFiles(ctx, root, opts.top, opts.min_bytes);
    try big.renderFiles(ctx, root, entries);
}

fn runDu(ctx: *ui.Ctx, opts: cli.Options) !void {
    const root = if (opts.paths.len != 0) opts.paths[0] else ctx.home;
    const entries = try big.dirBreakdown(ctx, root, opts.top);
    try big.renderDirs(ctx, root, entries);
    if (!ctx.json) try doctor.printDiskLine(ctx);
}

fn runDoctor(ctx: *ui.Ctx, opts: cli.Options) !void {
    const results = try scan.run(ctx, .{
        .level = .risky,
        .only = opts.only,
        .exclude = opts.exclude,
    });
    try doctor.run(ctx, results);
}

fn listRules(ctx: *ui.Ctx) !void {
    if (ctx.json) {
        try ctx.out.writeAll("{\n  \"rules\": [");
        var first = true;
        for (rules.rules) |rule| {
            try ctx.out.writeAll(if (first) "\n" else ",\n");
            first = false;
            try ctx.out.print(
                "    {{\"id\": \"{s}\", \"title\": \"{s}\", \"group\": \"{s}\", \"safety\": \"{s}\", \"needs_root\": {}}}",
                .{ rule.id, rule.title, rule.group.label(), rule.safety.label(), rule.needs_root },
            );
        }
        try ctx.out.writeAll("\n  ]\n}\n");
        return;
    }

    try ui.title(ctx, try std.fmt.allocPrint(ctx.arena, "Cleanup rules ({d})", .{rules.rules.len}));
    try ui.header(ctx, false, "ID");

    for (rules.rules) |rule| {
        try ctx.paint(ui.safetyColor(rule.safety));
        try humanize.writeLeftAligned(ctx.out, rule.safety.label(), ui.columns.safety);
        try ctx.reset();
        try ctx.out.print("  ", .{});
        try ctx.paint(ui.dim);
        try humanize.writeLeftAligned(ctx.out, rule.group.label(), ui.columns.group);
        try ctx.reset();
        try ctx.out.print("  ", .{});
        try humanize.writeLeftAligned(ctx.out, rule.id, 30);
        try ctx.out.print("  {s}\n", .{rule.title});

        if (ctx.verbose) {
            if (rule.why.len != 0) try ui.indent(ctx, rule.why);
            for (rule.paths) |path| try ui.indent(ctx, path);
            if (rule.kind == .command) try ui.indent(ctx, try rules.commandLine(ctx.arena, rule));
            if (rule.needs_root) try ui.indent(ctx, "system location - reported only, never deleted by mac-cleaner");
        }
    }

    try ctx.out.print("\n", .{});
    try ui.indent(ctx, "run `mac-cleaner list --verbose` for the full description of every rule");
}
