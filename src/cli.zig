//! Command line parsing.

const std = @import("std");
const humanize = @import("humanize.zig");
const rules = @import("rules.zig");

pub const version = "0.1.0";

pub const Command = enum {
    scan,
    audit,
    clean,
    artifacts,
    big,
    du,
    doctor,
    list,
    help,

    pub fn fromName(name: []const u8) ?Command {
        inline for (std.meta.fields(Command)) |field| {
            if (std.mem.eql(u8, name, field.name)) return @field(Command, field.name);
        }
        return null;
    }
};

pub const Options = struct {
    command: Command = .scan,
    /// `--version` was passed; print it and exit.
    version: bool = false,
    level: rules.Safety = .risky,
    level_set: bool = false,
    group: ?rules.Group = null,
    only: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    apply: bool = false,
    /// `--dry-run` always wins, even when `--apply` is also present.
    dry_run: bool = false,
    json: bool = false,
    color: ?bool = null,
    verbose: bool = false,
    quiet: bool = false,
    show_paths: bool = true,
    /// `--apply` was passed to a command that can never delete.
    apply_ignored: bool = false,
    /// Positional paths (`big`, `du`).
    paths: []const []const u8 = &.{},
    /// `--root` for `artifacts`.
    roots: []const []const u8 = &.{},
    depth: usize = 8,
    top: usize = 25,
    min_bytes: u64 = 0,
    include_extra: bool = false,
    extra: []const []const u8 = &.{},
};

pub const ParseError = error{
    MissingValue,
    UnknownFlag,
    UnknownCommand,
    InvalidLevel,
    InvalidGroup,
    InvalidNumber,
    InvalidSize,
} || std.mem.Allocator.Error;

fn splitCsv(arena: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, value, ", ");
    while (it.next()) |item| try list.append(arena, try arena.dupe(u8, item));
    return list.toOwnedSlice(arena);
}

fn flagValue(args: []const []const u8, index: *usize, arg: []const u8) ParseError![]const u8 {
    if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
        return arg[eq + 1 ..];
    }
    index.* += 1;
    if (index.* >= args.len) return error.MissingValue;
    return args[index.*];
}

pub fn parse(arena: std.mem.Allocator, argv: []const []const u8) ParseError!Options {
    var opts: Options = .{};
    var command_set = false;

    var positionals: std.ArrayList([]const u8) = .empty;
    var roots: std.ArrayList([]const u8) = .empty;

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.command = .help;
            return opts;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            opts.version = true;
            return opts;
        }
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            opts.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            opts.quiet = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            const name = if (std.mem.indexOfScalar(u8, arg, '=')) |eq| arg[0..eq] else arg;
            if (std.mem.eql(u8, name, "--level")) {
                const value = try flagValue(argv, &index, arg);
                opts.level = rules.Safety.fromName(value) orelse return error.InvalidLevel;
                opts.level_set = true;
            } else if (std.mem.eql(u8, name, "--group")) {
                const value = try flagValue(argv, &index, arg);
                opts.group = rules.Group.fromName(value) orelse return error.InvalidGroup;
            } else if (std.mem.eql(u8, name, "--only")) {
                opts.only = try splitCsv(arena, try flagValue(argv, &index, arg));
            } else if (std.mem.eql(u8, name, "--exclude")) {
                opts.exclude = try splitCsv(arena, try flagValue(argv, &index, arg));
            } else if (std.mem.eql(u8, name, "--root")) {
                try roots.append(arena, try arena.dupe(u8, try flagValue(argv, &index, arg)));
            } else if (std.mem.eql(u8, name, "--include")) {
                const value = try flagValue(argv, &index, arg);
                opts.extra = try splitCsv(arena, value);
                opts.include_extra = true;
            } else if (std.mem.eql(u8, name, "--depth")) {
                opts.depth = std.fmt.parseInt(usize, try flagValue(argv, &index, arg), 10) catch return error.InvalidNumber;
            } else if (std.mem.eql(u8, name, "--top")) {
                opts.top = std.fmt.parseInt(usize, try flagValue(argv, &index, arg), 10) catch return error.InvalidNumber;
            } else if (std.mem.eql(u8, name, "--min-size")) {
                opts.min_bytes = humanize.parseBytes(try flagValue(argv, &index, arg)) catch return error.InvalidSize;
            } else if (std.mem.eql(u8, name, "--apply")) {
                opts.apply = true;
            } else if (std.mem.eql(u8, name, "--dry-run")) {
                opts.dry_run = true;
            } else if (std.mem.eql(u8, name, "--json")) {
                opts.json = true;
            } else if (std.mem.eql(u8, name, "--no-color")) {
                opts.color = false;
            } else if (std.mem.eql(u8, name, "--color")) {
                opts.color = true;
            } else if (std.mem.eql(u8, name, "--no-paths")) {
                opts.show_paths = false;
            } else {
                return error.UnknownFlag;
            }
            continue;
        }

        if (!command_set) {
            if (Command.fromName(arg)) |command| {
                opts.command = command;
                command_set = true;
                continue;
            }
            if (arg.len != 0 and arg[0] == '-') return error.UnknownFlag;
            return error.UnknownCommand;
        }

        try positionals.append(arena, arg);
    }

    opts.paths = try positionals.toOwnedSlice(arena);
    opts.roots = try roots.toOwnedSlice(arena);

    // `clean` is a deletion command, so it defaults to the safe end of the range.
    if (opts.command == .clean and !opts.level_set) opts.level = .recreatable;

    // A dry run is a promise: it wins over any --apply on the same line.
    if (opts.dry_run) opts.apply = false;

    // `audit` is the read-only sweep; it has no deletion code at all.
    if (opts.command == .audit and opts.apply) {
        opts.apply = false;
        opts.apply_ignored = true;
    }

    return opts;
}

pub const help_text =
    \\usage: mac-cleaner [command] [options]
    \\
    \\Frees space on a long-lived developer Mac, safely.
    \\
    \\commands
    \\  audit        read-only sweep: rules + project build output + disk summary
    \\  scan         measure every known space hog (default, read only)
    \\  clean        delete reclaimable data; dry run unless --apply
    \\  artifacts    find node_modules, target, .zig-cache, ... in your projects
    \\  big          list the largest files under a path
    \\  du           show the size of each entry in a directory
    \\  doctor       disk summary and a suggested order of operations
    \\  list         show every cleanup rule and what it removes
    \\  help         this text
    \\
    \\options
    \\  --level <safe|recreatable|risky>  how much you are willing to delete
    \\                                    (scan: risky, clean: recreatable)
    \\  --group <name>                    only rules in one group
    \\  --only <id,id>                    only these rules
    \\  --exclude <id,id>                 never these rules
    \\  --apply                           actually delete (clean, artifacts)
    \\  --dry-run                         never delete, just report (wins over --apply)
    \\  --root <path>                     search path (artifacts, repeatable)
    \\  --depth <n>                       max recursion depth (artifacts, default 8)
    \\  --include <name,name>             also match dist, build, vendor, bin, obj
    \\  --top <n>                         rows to show (big, du; default 25)
    \\  --min-size <10M>                  ignore smaller files
    \\  --json                            machine readable output
    \\  --no-color, --color               force colour off or on
    \\  --no-paths                        hide paths in tables
    \\  -v, --verbose                     explain each rule and all its locations
    \\  -q, --quiet                       no progress output
    \\  -h, --help                        this text
    \\  -V, --version                     print the version
    \\
    \\safety
    \\  mac-cleaner only ever deletes inside your home folder. Anything owned
    \\  by macOS (/Library, /private, /System, /Applications, /Volumes, ...) is
    \\  reported for information and never touched, so the worst case is that
    \\  you have to reinstall a toolchain or re-pull some container images.
    \\  Credentials, keychains, mail, photos, browser profiles and your
    \\  Documents/Desktop/Downloads folders are protected too. Nothing happens
    \\  without --apply, and every run prints the list before it deletes.
    \\
    \\examples
    \\  mac-cleaner audit                    check everything, delete nothing
    \\  mac-cleaner scan                     what is using the disk? (read only)
    \\  mac-cleaner clean --dry-run          same answer, as a deletion plan
    \\  mac-cleaner clean                    show what would be deleted
    \\  mac-cleaner clean --level safe --apply
    \\  mac-cleaner artifacts --root ~/code --apply
    \\  mac-cleaner du ~ --top 15
    \\  mac-cleaner big ~/Downloads --top 10
    \\  mac-cleaner doctor
    \\
;

test "parses the default command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const opts = try parse(arena_state.allocator(), &.{"mac-cleaner"});
    try std.testing.expectEqual(Command.scan, opts.command);
    try std.testing.expectEqual(rules.Safety.risky, opts.level);
}

test "clean defaults to the recreatable level" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const opts = try parse(arena_state.allocator(), &.{ "mac-cleaner", "clean" });
    try std.testing.expectEqual(Command.clean, opts.command);
    try std.testing.expectEqual(rules.Safety.recreatable, opts.level);
}

test "parses flags with and without equals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const opts = try parse(arena, &.{
        "mac-cleaner", "clean", "--level", "safe",       "--only=npm-cache,go-build-cache",
        "--apply",     "--top", "5",       "--min-size", "10M",
    });
    try std.testing.expectEqual(rules.Safety.safe, opts.level);
    try std.testing.expect(opts.apply);
    try std.testing.expectEqual(@as(usize, 5), opts.top);
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024), opts.min_bytes);
    try std.testing.expectEqual(@as(usize, 2), opts.only.len);
    try std.testing.expectEqualStrings("go-build-cache", opts.only[1]);
}

test "collects positional paths and roots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const opts = try parse(arena, &.{ "mac-cleaner", "big", "/tmp", "--root", "/a", "--root=/b" });
    try std.testing.expectEqual(Command.big, opts.command);
    try std.testing.expectEqual(@as(usize, 1), opts.paths.len);
    try std.testing.expectEqualStrings("/tmp", opts.paths[0]);
    try std.testing.expectEqual(@as(usize, 2), opts.roots.len);
    try std.testing.expectEqualStrings("/b", opts.roots[1]);
}

test "short flags are parsed wherever they appear" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const opts = try parse(arena, &.{ "mac-cleaner", "big", "-v", "/tmp", "-q" });
    try std.testing.expect(opts.verbose);
    try std.testing.expect(opts.quiet);
    try std.testing.expectEqual(@as(usize, 1), opts.paths.len);
    try std.testing.expectEqualStrings("/tmp", opts.paths[0]);
}

test "dry run always wins over apply" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try parse(arena, &.{ "mac-cleaner", "clean", "--apply", "--dry-run" });
    try std.testing.expect(!a.apply);
    try std.testing.expect(a.dry_run);

    const b = try parse(arena, &.{ "mac-cleaner", "clean", "--dry-run", "--apply" });
    try std.testing.expect(!b.apply);

    const c = try parse(arena, &.{ "mac-cleaner", "clean", "--apply" });
    try std.testing.expect(c.apply);
}

test "audit is always read only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const opts = try parse(arena, &.{ "mac-cleaner", "audit", "--apply" });
    try std.testing.expectEqual(Command.audit, opts.command);
    try std.testing.expect(!opts.apply);
    try std.testing.expect(opts.apply_ignored);
}

test "rejects nonsense" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.UnknownCommand, parse(arena, &.{ "mac-cleaner", "frobnicate" }));
    try std.testing.expectError(error.UnknownFlag, parse(arena, &.{ "mac-cleaner", "--nope" }));
    try std.testing.expectError(error.InvalidLevel, parse(arena, &.{ "mac-cleaner", "--level", "yolo" }));
    try std.testing.expectError(error.MissingValue, parse(arena, &.{ "mac-cleaner", "--level" }));
    try std.testing.expectError(error.InvalidSize, parse(arena, &.{ "mac-cleaner", "--min-size", "big" }));
}
