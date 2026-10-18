//! Filesystem measurement helpers.

const std = @import("std");
const Io = std.Io;

pub const Totals = struct {
    bytes: u64 = 0,
    files: u64 = 0,
    dirs: u64 = 0,
    /// Newest modification time seen, in nanoseconds since the Unix epoch.
    newest_mtime_ns: i96 = 0,
    /// Entries we were not allowed to inspect.
    unreadable: u64 = 0,

    pub fn add(self: *Totals, other: Totals) void {
        self.bytes += other.bytes;
        self.files += other.files;
        self.dirs += other.dirs;
        self.unreadable += other.unreadable;
        if (other.newest_mtime_ns > self.newest_mtime_ns) {
            self.newest_mtime_ns = other.newest_mtime_ns;
        }
    }
};

/// Stat an absolute path without following a trailing symlink.
pub fn statPath(io: Io, abs_path: []const u8) !Io.File.Stat {
    const parent = std.fs.path.dirname(abs_path) orelse "/";
    const base = std.fs.path.basename(abs_path);
    var dir = try Io.Dir.openDirAbsolute(io, parent, .{});
    defer dir.close(io);
    return dir.statFile(io, base, .{ .follow_symlinks = false });
}

pub fn exists(io: Io, abs_path: []const u8) bool {
    _ = statPath(io, abs_path) catch return false;
    return true;
}

pub fn kindOf(io: Io, abs_path: []const u8) ?Io.File.Kind {
    const st = statPath(io, abs_path) catch return null;
    return st.kind;
}

/// Walks an absolute directory summing file sizes. Symlinks are never followed
/// and unreadable subtrees are skipped instead of aborting the whole walk.
pub fn measureTree(io: Io, gpa: std.mem.Allocator, abs_path: []const u8) Totals {
    var dir = Io.Dir.openDirAbsolute(io, abs_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch {
        var t: Totals = .{};
        t.unreadable = 1;
        return t;
    };
    defer dir.close(io);
    return measureOpenDir(io, gpa, dir);
}

/// Walks the contents of an already opened directory.
pub fn measureOpenDir(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) Totals {
    var totals: Totals = .{};

    var walker = dir.walkSelectively(gpa) catch {
        totals.unreadable = 1;
        return totals;
    };
    defer walker.deinit();

    while (true) {
        const maybe_entry = walker.next(io) catch |err| switch (err) {
            error.OutOfMemory => break,
            else => {
                // The walker always pops the failing directory before
                // returning, so looping again makes progress.
                totals.unreadable += 1;
                continue;
            },
        };
        const entry = maybe_entry orelse break;

        switch (entry.kind) {
            .directory => {
                totals.dirs += 1;
                walker.enter(io, entry) catch {
                    totals.unreadable += 1;
                };
            },
            .file => {
                const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch {
                    totals.unreadable += 1;
                    continue;
                };
                totals.bytes += st.size;
                totals.files += 1;
                if (st.mtime.nanoseconds > totals.newest_mtime_ns) {
                    totals.newest_mtime_ns = st.mtime.nanoseconds;
                }
            },
            else => {},
        }
    }

    return totals;
}

/// Sums the size of everything inside `abs_path`, without counting the
/// directory itself.
pub fn measureChildren(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, abs_path: []const u8) Totals {
    var totals: Totals = .{};

    var dir = Io.Dir.openDirAbsolute(io, abs_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch {
        totals.unreadable = 1;
        return totals;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const child = std.fmt.allocPrint(arena, "{s}/{s}", .{ abs_path, entry.name }) catch continue;
        totals.add(switch (entry.kind) {
            .directory => measureTree(io, gpa, child),
            .file => measureFile(io, child),
            else => Totals{},
        });
    }

    return totals;
}

pub fn measureFile(io: Io, abs_path: []const u8) Totals {
    var totals: Totals = .{};
    const st = statPath(io, abs_path) catch {
        totals.unreadable = 1;
        return totals;
    };
    totals.bytes = st.size;
    totals.files = 1;
    totals.newest_mtime_ns = st.mtime.nanoseconds;
    return totals;
}

/// Measures whatever sits at `abs_path`, dispatching on its kind.
pub fn measure(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, abs_path: []const u8, contents_only: bool) Totals {
    const kind = kindOf(io, abs_path) orelse {
        var t: Totals = .{};
        t.unreadable = 1;
        return t;
    };
    return switch (kind) {
        .directory => if (contents_only)
            measureChildren(io, gpa, arena, abs_path)
        else
            measureTree(io, gpa, abs_path),
        .file => measureFile(io, abs_path),
        else => Totals{},
    };
}

/// Lists the absolute paths of the direct children of a directory.
pub fn listChildren(io: Io, arena: std.mem.Allocator, abs_path: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;

    var dir = Io.Dir.openDirAbsolute(io, abs_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return out.toOwnedSlice(arena);

    defer dir.close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        // Defence in depth: never hand out `.` or `..`, even if a platform
        // ever starts returning them.
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const child = try std.fmt.allocPrint(arena, "{s}/{s}", .{ abs_path, entry.name });
        try out.append(arena, child);
    }
    return out.toOwnedSlice(arena);
}

test "Totals.add keeps the newest mtime" {
    var total: Totals = .{ .bytes = 10, .files = 1, .newest_mtime_ns = 5 };
    total.add(.{ .bytes = 5, .files = 2, .newest_mtime_ns = 9 });
    try std.testing.expectEqual(@as(u64, 15), total.bytes);
    try std.testing.expectEqual(@as(u64, 3), total.files);
    try std.testing.expectEqual(@as(i96, 9), total.newest_mtime_ns);

    total.add(.{ .bytes = 1, .files = 1, .newest_mtime_ns = 2 });
    try std.testing.expectEqual(@as(i96, 9), total.newest_mtime_ns);
}
