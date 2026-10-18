//! mac-cleaner: free up disk space on a long-lived developer Mac.
//!
//! The package root re-exports the pieces so tests can reach them through
//! `@import("mac_cleaner")`.

const std = @import("std");

pub const artifacts = @import("artifacts.zig");
pub const big = @import("big.zig");
pub const clean = @import("clean.zig");
pub const cli = @import("cli.zig");
pub const doctor = @import("doctor.zig");
pub const humanize = @import("humanize.zig");
pub const measure = @import("measure.zig");
pub const pathx = @import("pathx.zig");
pub const proc = @import("proc.zig");
pub const report = @import("report.zig");
pub const rules = @import("rules.zig");
pub const scan = @import("scan.zig");
pub const ui = @import("ui.zig");

test {
    std.testing.refAllDecls(@This());
}
