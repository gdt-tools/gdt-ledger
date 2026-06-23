//! Four metered allocator wrappers, one block each.
//!
//! Each wrapper pairs a standard allocation strategy with a ledger zone, so the
//! strategy's memory lands in the same counters as everything else:
//!   - ZonedArena: bump-allocate, then free everything at once with `reset`
//!   - ZonedPool(u64): fixed-size slots with free-list reuse
//!   - ZonedFixedBuffer: a caller-owned byte buffer, never touches the heap
//!   - ZonedDebug: leak and double-free checking layered on a zone
//!
//! Things to watch in the output: the pool hands the next `create` the slot a
//! `destroy` just freed; the fixed buffer's `reset` returns live bytes to zero
//! while `peakBytes` keeps the cumulative high-water mark; `ZonedDebug.deinit`
//! returns two verdicts in one call -- the zone's leak status and the wrapped
//! checker's.
//!
//! A separate `io` zone backs the stdout writer so its allocations stay out of
//! the per-wrapper numbers; the `DebugAllocator` backing fails the run on a leak.
//!
//! Run: `zig build run-wrappers`.

const std = @import("std");
const ledger = @import("gdt_ledger");

pub const gdt_ledger_options = .{
    .default_mode = .full,
};

pub var gdt_ledger_runtime: ledger.RootRuntime = .{};

const IoZone = ledger.Zone(.{
    .name = "io",
    .budget = 4096,
});

const ArenaZone = ledger.Zone(.{ .name = "arena_demo" });
const Arena = ledger.ZonedArena(ArenaZone);

const PoolZone = ledger.Zone(.{ .name = "pool_demo" });
const Pool = ledger.ZonedPool(u64, PoolZone);

const FbaZone = ledger.Zone(.{ .name = "fba_demo" });
const Fba = ledger.ZonedFixedBuffer(FbaZone);

const DebugZone = ledger.Zone(.{ .name = "debug_demo" });
const Debug = ledger.ZonedDebug(DebugZone, .{});

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();

    var io_zone = try IoZone.init(.{
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

    {
        var arena = try Arena.init(.{
            .backing_allocator = gpa,
            .control_allocator = gpa,
        });
        const ally = arena.allocator();

        _ = try ally.alloc(u8, 128);
        _ = try ally.alloc(u8, 256);

        try out.print("ZonedArena:\n", .{});
        try out.print("  after 2 allocs: {d} bytes\n", .{arena.currentBytes()});

        _ = arena.reset(.free_all);
        try out.print("  after reset:    {d} bytes\n", .{arena.currentBytes()});

        std.debug.assert(arena.deinit() == .ok);
        try out.print("  deinit: ok\n\n", .{});
    }

    {
        var pool = try Pool.init(.{
            .backing_allocator = gpa,
            .control_allocator = gpa,
        });

        const a = try pool.create();
        const b = try pool.create();
        a.* = 42;
        b.* = 99;

        try out.print("ZonedPool(u64):\n", .{});
        try out.print("  after 2 creates: {d} bytes\n", .{pool.currentBytes()});

        pool.destroy(a);
        const c = try pool.create();
        try out.print("  reused slot:     {}\n", .{c == a});

        _ = pool.reset(.free_all);
        try out.print("  after reset:     {d} bytes\n", .{pool.currentBytes()});

        std.debug.assert(pool.deinit() == .ok);
        try out.print("  deinit: ok\n\n", .{});
    }

    {
        // Caller-owned backing: the fixed buffer allocates from this slice and
        // never reaches for the heap, so it needs no backing_allocator.
        var backing: [512]u8 = undefined;
        var fba = try Fba.init(.{
            .buffer = &backing,
            .control_allocator = gpa,
        });
        const ally = fba.allocator();

        _ = try ally.alloc(u8, 64);
        _ = try ally.alloc(u8, 128);

        try out.print("ZonedFixedBuffer (512-byte backing):\n", .{});
        try out.print("  after 2 allocs: {d} bytes used\n", .{fba.currentBytes()});
        try out.print("  allocs:         {d}\n", .{fba.allocationCount()});

        fba.reset();
        try out.print("  after reset:    {d} bytes (cumulative peak: {d})\n", .{ fba.currentBytes(), fba.peakBytes() });

        std.debug.assert(fba.deinit() == .ok);
        try out.print("  deinit: ok\n\n", .{});
    }

    {
        var zdebug = try Debug.init(.{
            .backing_allocator = gpa,
            .control_allocator = gpa,
        });
        const ally = zdebug.allocator();

        const slice = try ally.alloc(u8, 256);
        try out.print("ZonedDebug:\n", .{});
        try out.print("  after 1 alloc: {d} bytes\n", .{zdebug.currentBytes()});
        ally.free(slice);
        try out.print("  after free:    {d} bytes\n", .{zdebug.currentBytes()});

        // deinit returns BOTH verdicts: the ledger zone status and the wrapped
        // DebugAllocator's leak check, in one call.
        const status = zdebug.deinit();
        try out.print("  deinit: zone={s}, debug={s}\n", .{ @tagName(status.zone), @tagName(status.debug) });
    }

    try out.flush();

    threaded.deinit();
    std.debug.assert(io_zone.deinit() == .ok);
}
