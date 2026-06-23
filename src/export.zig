//! Byte-count formatting helpers for dumps and example output.
//!
//! ASCII binary units (B / KiB / MiB / GiB), shared by the runtime dump writers
//! and the example programs so a byte figure reads the same everywhere.

const std = @import("std");

/// Write `bytes` to `writer` as a binary-unit string (B, KiB, MiB, GiB).
///
/// Picks the largest unit whose integer part stays below 1024: bytes are exact,
/// KiB/MiB carry one decimal, GiB two. ASCII only. Returns whatever error
/// `writer` returns.
pub fn fmtBytes(writer: *std.Io.Writer, bytes: usize) !void {
    if (bytes < 1024) {
        try writer.print("{d}B", .{bytes});
    } else if (bytes < 1024 * 1024) {
        try writer.print("{d:.1}KiB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    } else if (bytes < 1024 * 1024 * 1024) {
        try writer.print("{d:.1}MiB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
    } else {
        try writer.print("{d:.2}GiB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)});
    }
}

/// Format `bytes` into the caller's 16-byte buffer and return the written
/// slice, for callers that want a value instead of a writer error.
///
/// Returns "???" if the text would not fit, which only happens for byte counts
/// near the `usize` maximum (a multi-exabyte GiB figure overruns 16 bytes).
pub fn fmtBytesToBuf(buf: *[16]u8, bytes: usize) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    fmtBytes(&writer, bytes) catch return "???";
    return writer.buffered();
}

test "fmtBytes writes human readable units" {
    var buf: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try fmtBytes(&writer, 1536);
    try std.testing.expectEqualStrings("1.5KiB", writer.buffered());
}
