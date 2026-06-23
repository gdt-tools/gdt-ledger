//! Text and JSON formatting for the runtime registry.
//!
//! Both entry points take a `Runtime.snapshot()` and write it to a
//! `std.Io.Writer`: `dumpToWriter` an aligned human-readable table, `dumpToJson`
//! a compact JSON array. Both are inert (write nothing / "[]") when no `.full`
//! zones are registered. Formatting only; the registry and the snapshot live in
//! `root.zig`.

const std = @import("std");

const Runtime = @import("root.zig");
const fmtBytesToBuf = @import("../export.zig").fmtBytesToBuf;

/// Write the live zones as an aligned text table: indented by depth, with used /
/// peak / allocs / frees columns and budget/hardcap columns when any zone sets
/// them. Bytes use binary units; ASCII only. Writes nothing when no zones are
/// registered. Returns the writer's error.
pub fn dumpToWriter(writer: *std.Io.Writer) !void {
    const snap = Runtime.snapshot();
    if (snap.len == 0) return;
    var max_name: usize = 4;
    var max_used: usize = 4;
    var max_peak: usize = 4;
    var max_allocs: usize = 6;
    var max_frees: usize = 5;
    var max_budget: usize = 0;
    var max_hardcap: usize = 0;
    var has_budget = false;
    var has_hardcap = false;

    for (snap.infos[0..snap.len]) |info| {
        const name_w = info.depth * 2 + info.local_name.len;
        max_name = @max(max_name, name_w);

        var ubuf: [16]u8 = undefined;
        max_used = @max(max_used, fmtBytesToBuf(&ubuf, info.current_bytes).len);

        var pbuf: [16]u8 = undefined;
        max_peak = @max(max_peak, fmtBytesToBuf(&pbuf, info.peak_bytes).len);

        max_allocs = @max(max_allocs, countDigits(info.allocation_count));
        max_frees = @max(max_frees, countDigits(info.deallocation_count));

        if (info.budget > 0) {
            has_budget = true;
            var bbuf: [16]u8 = undefined;
            max_budget = @max(max_budget, fmtBytesToBuf(&bbuf, info.budget).len + 8);
        }

        if (info.hardcap > 0) {
            has_hardcap = true;
            var hbuf: [16]u8 = undefined;
            max_hardcap = @max(max_hardcap, fmtBytesToBuf(&hbuf, info.hardcap).len + 8);
        }
    }

    try writer.writeAll("Zone");
    try writePad(writer, max_name - 4 + 1);
    try writePad(writer, max_used - 4);
    try writer.writeAll("used");
    try writer.writeAll("  ");
    try writePad(writer, max_peak - 4);
    try writer.writeAll("peak");
    try writer.writeAll("  ");
    try writePad(writer, max_allocs - 6);
    try writer.writeAll("allocs");
    try writer.writeAll("  ");
    try writePad(writer, max_frees - 5);
    try writer.writeAll("frees");
    if (has_budget) {
        try writer.writeAll("  budget");
        try writePad(writer, max_budget - 6);
    }
    if (has_hardcap) {
        try writer.writeAll("  hardcap");
        try writePad(writer, max_hardcap - 7);
    }
    try writer.writeAll("\n");

    for (snap.infos[0..snap.len]) |info| {
        const indent = info.depth * 2;
        try writeIndent(writer, info.depth);
        try writer.print("{s}", .{info.local_name});
        try writePad(writer, max_name - (indent + info.local_name.len) + 1);

        var ubuf: [16]u8 = undefined;
        const used_s = fmtBytesToBuf(&ubuf, info.current_bytes);
        try writePad(writer, max_used - used_s.len);
        try writer.print("{s}", .{used_s});

        try writer.writeAll("  ");
        var pbuf: [16]u8 = undefined;
        const peak_s = fmtBytesToBuf(&pbuf, info.peak_bytes);
        try writePad(writer, max_peak - peak_s.len);
        try writer.print("{s}", .{peak_s});

        try writer.writeAll("  ");
        const alloc_w = countDigits(info.allocation_count);
        try writePad(writer, max_allocs - alloc_w);
        try writer.print("{d}", .{info.allocation_count});

        try writer.writeAll("  ");
        const free_w = countDigits(info.deallocation_count);
        try writePad(writer, max_frees - free_w);
        try writer.print("{d}", .{info.deallocation_count});

        if (has_budget) {
            try writer.writeAll("  ");
            if (info.budget > 0) {
                var bbuf: [16]u8 = undefined;
                const budget_s = fmtBytesToBuf(&bbuf, info.budget);
                try writePad(writer, max_budget - budget_s.len - 8);
                try writer.print("{s} ({d:.1}%)", .{ budget_s, info.budget_percent });
            } else {
                try writePad(writer, max_budget);
            }
        }

        if (has_hardcap) {
            try writer.writeAll("  ");
            if (info.hardcap > 0) {
                var hbuf: [16]u8 = undefined;
                const hardcap_s = fmtBytesToBuf(&hbuf, info.hardcap);
                try writePad(writer, max_hardcap - hardcap_s.len - 8);
                try writer.print("{s} ({d:.1}%)", .{ hardcap_s, info.hardcap_percent });
            } else {
                try writePad(writer, max_hardcap);
            }
        }

        try writer.writeAll("\n");
    }
}

/// Write the live zones as a compact JSON array, one object per zone. Names go
/// through `writeJsonString`, so quotes, backslashes, or control characters in a
/// name stay valid JSON. Writes "[]" when no zones are registered. Returns the
/// writer's error.
pub fn dumpToJson(writer: *std.Io.Writer) !void {
    const snap = Runtime.snapshot();
    try writer.writeAll("[");
    for (snap.infos[0..snap.len], 0..) |info, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"id\":{d},\"parent_id\":", .{info.id});
        if (info.parent_id) |parent_id| {
            try writer.print("{d}", .{parent_id});
        } else {
            try writer.writeAll("null");
        }

        try writer.writeAll(",\"name\":");
        try writeJsonString(writer, info.name);
        try writer.writeAll(",\"local_name\":");
        try writeJsonString(writer, info.local_name);
        try writer.writeAll(",\"parent_name\":");
        if (info.parent_name) |parent_name| {
            try writeJsonString(writer, parent_name);
        } else {
            try writer.writeAll("null");
        }

        try writer.print(
            ",\"depth\":{d},\"current_bytes\":{d},\"peak_bytes\":{d},\"allocation_count\":{d},\"deallocation_count\":{d},\"budget\":{d},\"budget_percent\":{d:.2},\"hardcap\":{d},\"hardcap_percent\":{d:.2},\"frame_delta\":{d},\"frame_allocs\":{d},\"frame_frees\":{d}}}",
            .{
                info.depth,
                info.current_bytes,
                info.peak_bytes,
                info.allocation_count,
                info.deallocation_count,
                info.budget,
                info.budget_percent,
                info.hardcap,
                info.hardcap_percent,
                info.frame_delta,
                info.frame_allocs,
                info.frame_frees,
            },
        );
    }
    try writer.writeAll("]");
}

// Write `value` as a quoted JSON string, escaping what JSON requires: '"', '\',
// and control characters (short escapes for the common ones, \u00XX otherwise).
// Lets dumpToJson accept any runtime-supplied name without producing invalid JSON.
fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u00{x:0>2}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

test "writeJsonString escapes runtime strings" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try writeJsonString(&writer, "a\"b\\c\n\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\u0001\"", writer.buffered());
}

test "fuzz writeJsonString emits parseable JSON strings" {
    if (comptime !@hasDecl(@import("root"), "fuzz")) return error.SkipZigTest;

    try std.testing.fuzz({}, fuzzWriteJsonString, .{});
}

fn fuzzWriteJsonString(_: void, smith: *std.testing.Smith) !void {
    var raw: [64]u8 = undefined;
    const len = smith.index(raw.len + 1);
    smith.bytes(raw[0..len]);

    for (raw[0..len]) |*byte| {
        byte.* &= 0x7f;
    }

    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeJsonString(&writer, raw[0..len]);

    const parsed = try std.json.parseFromSlice([]const u8, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();

    try std.testing.expectEqualSlices(u8, raw[0..len], parsed.value);
}

fn writeIndent(writer: *std.Io.Writer, depth: usize) !void {
    for (0..depth) |_| try writer.writeAll("  ");
}

fn writePad(writer: *std.Io.Writer, n: usize) !void {
    for (0..n) |_| try writer.writeAll(" ");
}

fn countDigits(value: usize) usize {
    if (value == 0) return 1;
    var v = value;
    var count: usize = 0;
    while (v > 0) : (v /= 10) count += 1;
    return count;
}
