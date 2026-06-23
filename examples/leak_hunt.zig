//! ZonedDebug pairing: one `deinit()`, two leak verdicts.
//!
//! Teaches what each layer answers when memory leaks. gdt-ledger says WHICH
//! subsystem leaked (the zone); the std DebugAllocator it wraps says WHICH
//! allocation (the stack trace). ZonedDebug stacks both, so a single `deinit()`
//! returns both verdicts. gdt-ledger never produces stack traces itself -- the
//! embedded std.heap.DebugAllocator does; ZonedDebug only bundles the pairing.
//! The scenario: a physics zone leaks a frame buffer on purpose, so the run
//! prints both verdicts and the DebugAllocator prints the leaking allocation's
//! stack trace to stderr.
//!
//! Run: `zig build run-leak-hunt`.

const std = @import("std");
const ledger = @import("gdt_ledger");

pub const gdt_ledger_options = .{
    .default_mode = .full,
};

pub var gdt_ledger_runtime: ledger.RootRuntime = .{};

const PhysicsZone = ledger.Zone(.{ .name = "physics" });
const PhysicsDebug = ledger.ZonedDebug(PhysicsZone, .{});

pub fn main(init: std.process.Init.Minimal) !void {
    // page_allocator is the raw backing on purpose: a leak-checking backing would
    // report the orphaned bytes a SECOND time at exit. The verdict we want comes
    // from the DebugAllocator that ZonedDebug embeds, not from the backing.
    const raw = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(raw, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buf);
    const out = &file_writer.interface;

    var hunt = try PhysicsDebug.init(.{
        .backing_allocator = raw,
        .control_allocator = raw,
    });

    // The physics subsystem allocates a frame buffer and "forgets" to free it
    // across a level load -- the bug we are hunting.
    const frame = try hunt.allocator().alloc(u8, 4096);
    _ = frame; // never freed: this is the staged leak

    const leaked = hunt.currentBytes();
    const live = hunt.allocationCount() - hunt.deallocationCount();
    const name = hunt.zoneName();

    var byte_buf: [16]u8 = undefined;
    var byte_writer: std.Io.Writer = .fixed(&byte_buf);
    try ledger.fmtBytes(&byte_writer, leaked);
    const leaked_str = byte_writer.buffered();

    // One call. Two verdicts. The embedded DebugAllocator also prints the
    // leaking allocation's stack trace to stderr as a side effect of this deinit.
    const v = hunt.deinit();

    try out.print("leak hunt -- one deinit(), two verdicts:\n", .{});
    try out.print("  ledger  zone={s}  status={s}  {s} over {d} live alloc\n", .{ name, @tagName(v.zone), leaked_str, live });
    try out.print("  debug   status={s}\n", .{@tagName(v.debug)});
    try out.flush();
}
