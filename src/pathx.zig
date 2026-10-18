//! Path expansion for rule patterns.
//!
//! Rule patterns are absolute paths that may start with `~` and may contain
//! `*` / `?` wildcards in any path component, e.g.
//! `~/.gem/ruby/*/cache` or `~/Library/Caches/Google/AndroidStudio*`.

const std = @import("std");
const builtin = @import("builtin");

pub fn hasGlob(component: []const u8) bool {
    return std.mem.indexOfAny(u8, component, "*?") != null;
}

/// Shell style single component matching supporting `*` and `?`.
pub fn componentMatches(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var backtrack_p: ?usize = null;
    var backtrack_n: usize = 0;

    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            backtrack_p = p;
            p += 1;
            backtrack_n = n;
        } else if (backtrack_p) |bp| {
            p = bp + 1;
            backtrack_n += 1;
            n = backtrack_n;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Replaces a leading `~` with `home`. Non-absolute patterns are returned as is.
pub fn withHome(arena: std.mem.Allocator, home: []const u8, pattern: []const u8) ![]const u8 {
    if (std.mem.eql(u8, pattern, "~")) return arena.dupe(u8, home);
    if (std.mem.startsWith(u8, pattern, "~/")) {
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ home, pattern[2..] });
    }
    return arena.dupe(u8, pattern);
}

/// Expands a pattern into every existing absolute path it matches.
/// The returned slices are owned by `arena`. Unreadable directories are
/// silently skipped, which is what we want for system owned locations.
pub fn expand(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    pattern: []const u8,
) ![]const []const u8 {
    const full = try withHome(arena, home, pattern);
    if (!std.fs.path.isAbsolute(full) or std.mem.indexOfAny(u8, full, "*?") == null) {
        return arena.dupe([]const u8, &.{full});
    }

    // Walk the pattern one component at a time, expanding wildcards against
    // the real directory tree.
    const root = rootOf(full);
    var prefixes: std.ArrayList([]const u8) = .empty;
    try prefixes.append(arena, try arena.dupe(u8, root));

    var it = std.mem.tokenizeAny(u8, full[root.len..], "/\\");
    while (it.next()) |component| {
        var next: std.ArrayList([]const u8) = .empty;
        for (prefixes.items) |prefix| {
            if (hasGlob(component)) {
                var dir = std.Io.Dir.openDirAbsolute(io, openableRoot(arena, prefix) catch continue, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch continue;
                defer dir.close(io);

                var iter = dir.iterate();
                while (iter.next(io) catch null) |entry| {
                    if (!componentMatches(component, entry.name)) continue;
                    try next.append(arena, try std.fs.path.join(arena, &.{ prefix, entry.name }));
                }
            } else {
                try next.append(arena, try std.fs.path.join(arena, &.{ prefix, component }));
            }
        }
        prefixes = next;
    }

    return arena.dupe([]const u8, prefixes.items);
}

fn isSep(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

/// The absolute root of `path`: `/`, `C:\`, `\\server\share\`, or empty.
fn rootOf(path: []const u8) []const u8 {
    if (builtin.os.tag == .windows) {
        const designator = std.fs.path.diskDesignatorWindows(path);
        if (designator.len != 0) return designator;
    }
    if (path.len != 0 and path[0] == '/') return path[0..1];
    return "";
}

/// A bare drive designator such as `C:` is not an absolute directory, so add
/// the separator before opening it.
fn openableRoot(arena: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    if (prefix.len == 0) return ".";
    if (prefix.len >= 2 and prefix[1] == ':' and !isSep(prefix[prefix.len - 1])) {
        return std.fmt.allocPrint(arena, "{s}{c}", .{ prefix, std.fs.path.sep });
    }
    return prefix;
}

test "componentMatches" {
    try std.testing.expect(componentMatches("*.dmg", "x.dmg"));
    try std.testing.expect(!componentMatches("*.dmg", "x.pkg"));
    try std.testing.expect(componentMatches("Chrome*", "Chrome Beta"));
    try std.testing.expect(componentMatches("a?c", "abc"));
    try std.testing.expect(!componentMatches("a?c", "ac"));
    try std.testing.expect(componentMatches("*", ""));
    try std.testing.expect(componentMatches("*", "anything"));
    try std.testing.expect(!componentMatches("abc", "abcd"));
    try std.testing.expect(componentMatches("a*b*c", "aXXbYYc"));
    try std.testing.expect(!componentMatches("a*b*c", "aXXbYY"));
}

test "expand resolves wildcards against a real tree" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "Caches/Google/Chrome");
    try tmp.dir.createDirPath(io, "Caches/Google/Chrome Beta");
    try tmp.dir.createDirPath(io, "Caches/Apple");

    const cwd = try std.process.currentPathAlloc(io, arena);
    const home = try std.fmt.allocPrint(arena, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path[0..] });

    const chrome = try expand(arena, io, home, "~/Caches/Google/Chrome*");
    try std.testing.expectEqual(@as(usize, 2), chrome.len);

    const apple = try expand(arena, io, home, "~/Caches/A*");
    try std.testing.expectEqual(@as(usize, 1), apple.len);

    const none = try expand(arena, io, home, "~/Caches/Nope*");
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // A pattern without wildcards is passed through untouched, even if missing.
    const plain = try expand(arena, io, home, "~/Caches/Apple");
    try std.testing.expectEqual(@as(usize, 1), plain.len);
}

test "withHome expands tilde" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("/Users/me/Library/Caches", try withHome(arena, "/Users/me", "~/Library/Caches"));
    try std.testing.expectEqualStrings("/Users/me", try withHome(arena, "/Users/me", "~"));
    try std.testing.expectEqualStrings("/var/tmp", try withHome(arena, "/Users/me", "/var/tmp"));
}
