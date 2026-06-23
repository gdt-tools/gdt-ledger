//! Smallest useful setup: one zone, one allocation, the core counters.
//!
//! Teaches the per-zone counters (live bytes, peak, allocation count) and the
//! two limits a zone can carry: `budget`, a soft target reported as a percent,
//! and `hardcap`, a hard ceiling that makes an over-limit allocation fail. The
//! takeaway to watch for in the output: after `free`, `currentBytes` drops back
//! to zero but `peakBytes` holds at the high-water mark, because peak is the
//! figure you size pools and budgets against.
//!
//! A separate `io` zone backs the stdout writer so its allocations stay out of
//! the demo zone's numbers; the `DebugAllocator` backing fails the run on a leak.
//!
//! Run: `zig build run-basic`.

const std = @import("std");

const ledger = @import("gdt_ledger");

pub const gdt_ledger_options = .{
    .default_mode = .full,
};

pub var gdt_ledger_runtime: ledger.RootRuntime = .{};

const Io = ledger.Zone(.{
    .name = "io",
    .budget = 4096,
});

const Demo = ledger.Zone(.{
    .name = "demo",
    .budget = 1024, // soft target: reported as a percent, never enforced
    .hardcap = 2048, // hard ceiling: an allocation that would cross it fails
});

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();

    var zone = try Demo.init(.{
        .backing_allocator = gpa,
        .control_allocator = gpa,
    });
    var io_zone = try Io.init(.{
        .backing_allocator = gpa,
        .control_allocator = gpa,
    });

    var threaded: std.Io.Threaded = .init(io_zone.allocator(), .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    const io = threaded.io();

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buf);
    const out = &file_writer.interface;

    const ally = zone.allocator();
    const slice = try ally.alloc(u8, 256);

    try out.print("After alloc:\n", .{});
    try out.print("  currentBytes: {d}\n", .{zone.currentBytes()});
    try out.print("  peakBytes:    {d}\n", .{zone.peakBytes()});
    try out.print("  allocs:       {d}\n", .{zone.allocationCount()});
    try out.print("  budget:       {d:.1}%\n", .{zone.budgetPercent()});
    try out.print("  hardcap:      {d:.1}%\n\n", .{zone.hardcapPercent()});

    ally.free(slice);

    try out.print("After free:\n", .{});
    try out.print("  currentBytes: {d}\n", .{zone.currentBytes()});
    try out.print("  peakBytes:    {d} (peak survives)\n\n", .{zone.peakBytes()});

    try out.print("Runtime dump:\n", .{});
    try ledger.dumpToWriter(out);
    try out.print("\n", .{});

    std.debug.assert(zone.deinit() == .ok);

    try out.print("deinit: ok (no leaks)\n", .{});
    try out.flush();

    threaded.deinit();
    std.debug.assert(io_zone.deinit() == .ok);
}
