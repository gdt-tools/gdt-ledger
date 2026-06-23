//! Parent/child zones and how a child's bytes roll up into its ancestors.
//!
//! `bullets` is a subzone of `physics`. Allocating through the child's allocator
//! charges the child and every ancestor at once: after a 512-byte alloc in
//! `bullets`, `physics.currentBytes` includes those 512 bytes, because a child's
//! allocations chain through the parent that backs it. Freeing rolls the bytes
//! back out of both. The runtime dump prints the whole tree, indented by depth.
//!
//! A separate `io` zone backs the stdout writer so its allocations stay out of
//! the measured numbers; the `DebugAllocator` backing fails the run on a leak.
//!
//! Run: `zig build run-subzones`.

const std = @import("std");

const ledger = @import("gdt_ledger");
const Zone = ledger.Zone;

pub const gdt_ledger_options = .{
    .default_mode = .full,
};

pub var gdt_ledger_runtime: ledger.RootRuntime = .{};

const Io = Zone(.{
    .name = "io",
    .budget = 4096,
});

const Physics = Zone(.{
    .name = "physics",
    .budget = 4096,
});

const Bullets = Physics.subzone(.{
    .name = "bullets",
    .budget = 1024,
});

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();

    var zone_io = try Io.init(.{
        .backing_allocator = gpa,
        .control_allocator = gpa,
    });
    var physics = try Physics.init(.{
        .backing_allocator = gpa,
        .control_allocator = gpa,
    });
    // initUnder attaches bullets beneath physics; from here its allocations
    // charge bullets and roll up through physics.
    var bullets = try Bullets.initUnder(.{ .parent = &physics });

    var threaded: std.Io.Threaded = .init(zone_io.allocator(), .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    const io = threaded.io();

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buf);
    const out = &file_writer.interface;

    const ally = bullets.allocator();
    const slice = try ally.alloc(u8, 512);

    try out.print("After allocating 512 bytes in bullets:\n", .{});
    try out.print("       io.currentBytes: {d}\n", .{zone_io.currentBytes()});
    try out.print("  bullets.currentBytes: {d}\n", .{bullets.currentBytes()});
    try out.print("  physics.currentBytes: {d} (parent sees child allocs)\n\n", .{physics.currentBytes()});

    ally.free(slice);

    try out.print("After free:\n", .{});
    try out.print("       io.currentBytes: {d}\n", .{zone_io.currentBytes()});
    try out.print("  bullets.currentBytes: {d}\n", .{bullets.currentBytes()});
    try out.print("  physics.currentBytes: {d}\n\n", .{physics.currentBytes()});

    try out.print("Runtime tree:\n", .{});
    try ledger.dumpToWriter(out);
    try out.print("\n", .{});

    std.debug.assert(bullets.deinit() == .ok);
    std.debug.assert(physics.deinit() == .ok);

    try out.print("deinit: ok\n", .{});
    try out.flush();

    threaded.deinit();
    std.debug.assert(zone_io.deinit() == .ok);
}
