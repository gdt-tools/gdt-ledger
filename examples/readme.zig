//! The README's "Quick Flex" snippet, kept here as a real program so the output
//! the README shows is produced by this code, not typed in by hand.
//!
//! One `physics` zone, one allocation, and the headline counters in a single
//! line: live bytes, peak, allocation count, and the two limits as percentages -
//! `budget`, a soft gauge you read, and `hardcap`, the hard ceiling that makes an
//! over-limit allocation fail. The 2 MiB allocation is sized against the 64 MiB
//! budget and 256 MiB hardcap so both percentages print as visible, non-zero
//! figures instead of rounding to 0.0%.
//!
//! `frame_tracking` is on and `markFrame()` closes the frame, so the per-frame
//! delta path runs even though this short demo only prints the running totals.
//!
//! Run: `zig build run-readme`.

const std = @import("std");
const ledger = @import("gdt_ledger");

// Policy lives in your root.
pub const gdt_ledger_options = .{ .default_mode = .full };
pub var gdt_ledger_runtime: ledger.RootRuntime = .{};

const Physics = ledger.Zone(.{
    .name = "physics",
    .budget = 64 * 1024 * 1024, // soft: a gauge you read
    .hardcap = 256 * 1024 * 1024, // hard: this zone's alloc FAILS, no one else's
    .frame_tracking = true,
});

pub fn main() !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    const gpa = dbg.allocator();

    var physics = try Physics.init(.{
        .backing_allocator = gpa, // where the user's bytes go
        .control_allocator = gpa, // where ledger keeps its own books
    });
    defer std.debug.assert(physics.deinit() == .ok); // .ok / .leak / .live_children

    const ally = physics.allocator();
    const sim = try ally.alloc(u8, 2 * 1024 * 1024);
    defer ally.free(sim);

    physics.markFrame();

    std.debug.print("used={} peak={} allocs={} budget={d:.1}% hardcap={d:.1}%\n", .{
        physics.currentBytes(),
        physics.peakBytes(),
        physics.allocationCount(),
        physics.budgetPercent(),
        physics.hardcapPercent(),
    });
}
