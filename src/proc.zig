//! Running external commands (docker, brew, tmutil, df, ...).

const std = @import("std");
const ui = @import("ui.zig");

pub const Output = struct {
    ok: bool = false,
    /// The executable itself could not be found.
    not_found: bool = false,
    status: ?u8 = null,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

/// Runs a command, capturing its output. All memory comes from the session
/// arena so callers never have to free anything.
pub fn run(ctx: *ui.Ctx, argv: []const []const u8) Output {
    const result = std.process.run(ctx.arena, ctx.io, .{
        .argv = argv,
        .stdout_limit = .limited(8 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        return .{
            .not_found = err == error.FileNotFound,
            .stderr = @errorName(err),
        };
    };

    const status: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };
    return .{
        .ok = status == 0,
        .status = status,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// Runs a command and returns the first line of stdout, trimmed.
pub fn firstLine(ctx: *ui.Ctx, argv: []const []const u8) ?[]const u8 {
    const out = run(ctx, argv);
    if (!out.ok) return null;
    const trimmed = std.mem.trim(u8, out.stdout, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..end], " \t\r");
}

test "not_found is reported for a missing executable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var err_writer = std.Io.Writer.fixed(&err_buf);

    var ctx: ui.Ctx = .{
        .gpa = std.testing.allocator,
        .arena = arena_state.allocator(),
        .io = std.testing.io,
        .out = &out_writer,
        .err = &err_writer,
        .home = "/tmp",
    };

    const result = run(&ctx, &.{"definitely-not-a-real-binary-1234"});
    try std.testing.expect(!result.ok);
    try std.testing.expect(result.not_found);
    try std.testing.expectEqual(@as(?u8, null), result.status);
}
