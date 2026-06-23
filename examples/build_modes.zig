//! Void elimination made visible: the same source under `.off`, `.guardrails`,
//! and `.full`.
//!
//! The instrumentation mode comes from a build option, so one file runs at every
//! level without an edit. The teaching is in the `Zone.State` and `Zone.Impl`
//! lines -- the durable per-zone storage. At `.full` they hold the counter block;
//! at `.off` both are 0 bytes, because every disabled field has type `void` and
//! contributes nothing. (The handle type itself is not the storage: an `.off`
//! handle has no heap state to point at, so it carries its allocator inline and
//! its size does not drop to zero -- watch State and Impl, not the handle.) The
//! accounting calls (`currentBytes`, `frameDelta`) still compile at `.off` -- they
//! return zero and generate no code -- so an instrumented build and a shipping
//! build share one source with no `#ifdef`-style forking.
//!
//! Run: `zig build run-build-modes` for `.full`, then re-run with
//! `-Dledger-mode=guardrails` and `-Dledger-mode=off` and compare the sizes.

const std = @import("std");
const ledger = @import("gdt_ledger");

// Mode is selected at build time via `-Dledger-mode`; the build wires it in here.
const ledger_options = @import("gdt_ledger_example_options");

pub const gdt_ledger_options = .{
    .default_mode = ledger_options.default_mode,
};

pub var gdt_ledger_runtime: ledger.RootRuntime = .{};

const ZoneIo = ledger.Zone(.{
    .name = "io",
    .budget = 4096,
});

const Zone = ledger.Zone(.{
    .name = "mode_demo",
    .budget = 1024,
    .hardcap = 2048,
    .frame_tracking = true,
});

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();

    var zone = try Zone.init(.{
        .backing_allocator = gpa,
        .control_allocator = gpa,
    });
    var zone_io = try ZoneIo.init(.{
        .backing_allocator = gpa,
        .control_allocator = gpa,
    });

    var threaded: std.Io.Threaded = .init(zone_io.allocator(), .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    const io = threaded.io();

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buf);
    const out = &file_writer.interface;

    try out.print("Default mode: {s}\n\n", .{@tagName(gdt_ledger_options.default_mode)});

    // The void-elimination payoff is in State/Impl below: both go to 0 bytes at
    // `.off`. The handle sizes (ZoneIo/Zone) are not the storage; ignore them.
    try out.print("@sizeOf(ZoneIo):      {d} bytes\n", .{@sizeOf(ZoneIo)});
    try out.print("@sizeOf(Zone):        {d} bytes\n", .{@sizeOf(Zone)});
    try out.print("@sizeOf(Zone.State):  {d} bytes\n", .{@sizeOf(Zone.State)});
    try out.print("@sizeOf(Zone.Impl):   {d} bytes\n\n", .{@sizeOf(Zone.Impl)});

    const ally = zone.allocator();
    const slice = try ally.alloc(u8, 256);

    try out.print("After allocating 256 bytes:\n", .{});
    try out.print("  currentBytes: {d}\n", .{zone.currentBytes()});
    try out.print("  peakBytes:    {d}\n", .{zone.peakBytes()});
    try out.print("  frameDelta:   {d}\n\n", .{zone.frameDelta()});

    ally.free(slice);

    const zone_status = zone.deinit();
    try out.print("zone deinit: {s}\n", .{@tagName(zone_status)});

    try out.print("\nTry: zig build run-build-modes -Dledger-mode=guardrails\n", .{});
    try out.print("     zig build run-build-modes -Dledger-mode=off\n", .{});
    try out.flush();

    threaded.deinit();
    const zone_io_status = zone_io.deinit();
    std.debug.assert(zone_io_status == .ok);
}
