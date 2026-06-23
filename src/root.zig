//! gdt-ledger: hierarchical memory accounting with no per-allocation metadata.
//!
//! Named zones wrap a backing allocator and keep aggregate counters (live
//! bytes, peak, alloc/free counts, optional frame deltas) plus optional budgets
//! and hardcaps. There is no per-allocation header: accounting is a handful of
//! integers per zone, updated on the allocator vtable path.
//!
//! Policy is owned by the application root, not the library. The root declares
//! `gdt_ledger_options` (default mode + scope rules) and, for `.full`,
//! `gdt_ledger_runtime` storage; the library reads both structurally through
//! `@import("root")` so multiple module instances agree without nominal type
//! equality. Two independent mechanisms decide a zone's effective mode:
//!
//! - rules select by name: a scoped zone resolves its mode by longest-prefix
//!   match against the root rule list, and a deeper rule may raise or lower it;
//! - subzones clamp by allocation: a child created under a parent runs at
//!   `min(parent, child)`, because its allocations chain through the parent.
//!
//! With no `gdt_ledger_options` in root, every zone is `.off` and its state is
//! void-eliminated to zero bytes, leaving the bare backing allocator.
//!
//! This file is the public facade: re-exports only. Each contract is documented
//! at its definition site.

const Runtime = @import("runtime/root.zig");

const policy = @import("policy.zig");
const capabilities = @import("capabilities.zig");

pub const ZoneConfig = @import("config/zone.zig");
pub const SubzoneConfig = @import("config/subzone.zig");
pub const Zone = @import("zone/root.zig").Zone;
pub const scope = @import("zone/root.zig").scope;
pub const validateRules = policy.validateRules;
pub const ZonedArena = @import("wrappers/arena.zig").ZonedArena;
pub const ZonedDebug = @import("wrappers/debug.zig").ZonedDebug;
pub const ZonedFixedBuffer = @import("wrappers/fixed_buffer.zig").ZonedFixedBuffer;
pub const ZonedPool = @import("wrappers/pool.zig").ZonedPool;
pub const ZonedPoolAligned = @import("wrappers/pool.zig").ZonedPoolAligned;
pub const ZonedPoolExtra = @import("wrappers/pool.zig").ZonedPoolExtra;
pub const ZoneInfo = Runtime.ZoneInfo;
pub const DeinitStatus = Runtime.DeinitStatus;
pub const RootRuntime = Runtime.RootRuntime;
pub const LedgerMode = policy.LedgerMode;
pub const Capabilities = capabilities.Capabilities;
pub const fmtBytes = @import("export.zig").fmtBytes;

pub const zoneCount = Runtime.zoneCount;
pub const unsafeResetForTest = Runtime.unsafeResetForTest;
pub const snapshot = Runtime.snapshot;
pub const dumpToWriter = Runtime.dumpToWriter;
pub const dumpToJson = Runtime.dumpToJson;

const std = @import("std");

test {
    _ = @import("export.zig");
    _ = @import("runtime/root.zig");
    _ = @import("runtime/dump.zig");
    _ = @import("capabilities.zig");
    _ = @import("zone/frames.zig");
    _ = @import("zone/lifecycle.zig");
    _ = @import("accounting/meter.zig");
    _ = @import("policy.zig");
    _ = @import("tracy.zig");
    _ = @import("validation.zig");
    _ = @import("config/subzone.zig");
    _ = @import("accounting/tracked_allocator.zig");
    _ = @import("zone/root.zig");
    _ = @import("config/zone.zig");
    _ = @import("zone/enabled.zig");
    _ = @import("wrappers/arena.zig");
    _ = @import("wrappers/debug.zig");
    _ = @import("wrappers/fixed_buffer.zig");
    _ = @import("wrappers/pool.zig");
}

test "void elimination keeps disabled state out of impl" {
    if (comptime policy.default_mode != .full) return error.SkipZigTest;

    const TrackedAllocator = @import("accounting/tracked_allocator.zig").TrackedAllocator;

    const FullTracked = TrackedAllocator(.{ .enable_stats = true, .enable_memory_limit = true });
    const MinTracked = TrackedAllocator(.{ .enable_stats = false, .enable_memory_limit = false });
    try std.testing.expect(@sizeOf(MinTracked.State) < @sizeOf(FullTracked.State));

    const FullZone = Zone(.{ .name = "a", .frame_tracking = true, .hardcap = 1024 });
    const MinZone = Zone(.{ .name = "b", .frame_tracking = false });
    try std.testing.expect(@sizeOf(MinZone.Impl) < @sizeOf(FullZone.Impl));
}

test "guardrails mode keeps limits and counters but disables runtime export and frame stats" {
    if (comptime policy.default_mode != .guardrails) return error.SkipZigTest;

    const Guarded = Zone(.{
        .name = "guardrails",
        .budget = 64,
        .hardcap = 96,
        .frame_tracking = true,
    });
    var zone = try Guarded.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    const ally = zone.allocator();

    const a = try ally.alloc(u8, 48);

    try std.testing.expectEqual(@as(usize, 48), zone.currentBytes());
    try std.testing.expectEqual(@as(usize, 48), zone.peakBytes());
    try std.testing.expectEqual(@as(usize, 1), zone.allocationCount());
    try std.testing.expectEqual(@as(f32, 75.0), zone.budgetPercent());
    try std.testing.expectEqual(@as(f32, 50.0), zone.hardcapPercent());

    zone.markFrame();
    try std.testing.expectEqual(@as(i64, 0), zone.frameDelta());
    try std.testing.expectEqual(@as(usize, 0), zone.frameAllocs());
    try std.testing.expectEqual(@as(usize, 0), zone.frameFrees());

    try std.testing.expectEqual(@as(usize, 0), zoneCount());

    var text_buf: [128]u8 = undefined;
    var text_writer: std.Io.Writer = .fixed(&text_buf);
    try dumpToWriter(&text_writer);
    try std.testing.expectEqualStrings("", text_writer.buffered());

    var json_buf: [128]u8 = undefined;
    var json_writer: std.Io.Writer = .fixed(&json_buf);
    try dumpToJson(&json_writer);
    try std.testing.expectEqualStrings("[]", json_writer.buffered());

    try std.testing.expectError(error.OutOfMemory, ally.alloc(u8, 64));
    ally.free(a);
    try std.testing.expectEqual(DeinitStatus.ok, zone.deinit());
}

test "off mode state is minimal and allocator is backing passthrough" {
    if (comptime policy.default_mode != .off) return error.SkipZigTest;

    const Off = Zone(.{ .name = "off", .hardcap = 1024, .frame_tracking = true });
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Off.State));

    var zone = try Off.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    const ally = zone.allocator();
    try std.testing.expectEqual(std.testing.allocator.ptr, ally.ptr);

    const slice = try ally.alloc(u8, 64);
    ally.free(slice);

    try std.testing.expectEqual(@as(usize, 0), zone.currentBytes());
    try std.testing.expectEqual(@as(usize, 0), zone.allocationCount());
    try std.testing.expectEqual(DeinitStatus.ok, zone.deinit());
}
