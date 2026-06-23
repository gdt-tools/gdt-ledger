//! `ZonedFixedBuffer`: meter a `std.heap.FixedBufferAllocator` by its retained
//! footprint (the buffer's high-water `end_index`).
//!
//! A fixed buffer has no backing allocator to chain a zone through, and only
//! rewinds on a last-allocation free, so its accounting differs from a normal
//! zone in two ways this wrapper makes explicit:
//! - `currentBytes` is the retained `end_index`: it includes alignment padding
//!   and bytes from non-LIFO frees that could not be rewound;
//! - `deinit` reports `.leak` from an alloc/free *call* imbalance, not from
//!   `currentBytes != 0`, since a fully-but-non-LIFO-freed buffer still retains
//!   footprint.
//! The hardcap therefore caps `end_index`, not live requested bytes. Root zones
//! only: a subzone `ZoneDef` is rejected at comptime.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const lifecycle = @import("../zone/lifecycle.zig");
const Runtime = @import("../runtime/root.zig");
const ZoneInfo = Runtime.ZoneInfo;

/// Wrap a fixed buffer in the zone defined by `ZoneDef`. Root zones only -- a
/// subzone `ZoneDef` is a `@compileError` because `FixedBufferAllocator` has no
/// backing allocator to chain through.
pub fn ZonedFixedBuffer(comptime ZoneDef: type) type {
    comptime {
        if (ZoneDef.is_subzone) {
            @compileError("gdt-ledger: ZonedFixedBuffer does not support subzones yet; FixedBufferAllocator has no backing allocator chain");
        }
    }

    return struct {
        impl: ?*Impl,

        const Self = @This();

        pub const InitOptions = struct {
            buffer: []u8,
            control_allocator: Allocator,
        };

        const RuntimeStorage = if (ZoneDef.capabilities.runtime_export) struct {
            lifecycle_header: lifecycle.Header,
            runtime_export: Runtime.Export,
        } else struct {
            control_allocator: Allocator,
        };

        pub const Impl = struct {
            runtime: RuntimeStorage,
            fba: std.heap.FixedBufferAllocator,
            zone_state: ZoneDef.State = .{},
        };

        /// Create the wrapper over `buffer`. `control_allocator` holds the
        /// wrapper state; the metered storage is the caller's `buffer`, which
        /// must outlive the wrapper. Under `.full`, registers in the runtime for
        /// dumps.
        ///
        /// # Errors
        /// `error.OutOfMemory` if the control allocator cannot allocate the impl.
        pub fn init(options: InitOptions) !Self {
            if (comptime ZoneDef.capabilities.runtime_export) Runtime.requireRuntime();

            const impl = try options.control_allocator.create(Impl);
            errdefer options.control_allocator.destroy(impl);

            if (comptime ZoneDef.capabilities.runtime_export) {
                lifecycle.init(&impl.runtime.lifecycle_header, options.control_allocator, null);
                Runtime.initExport(&impl.runtime.runtime_export, null);
            } else {
                impl.runtime = .{ .control_allocator = options.control_allocator };
            }
            impl.fba = std.heap.FixedBufferAllocator.init(options.buffer);
            impl.zone_state = .{};
            if (comptime ZoneDef.capabilities.runtime_export) {
                Runtime.link(&impl.runtime.runtime_export, impl, &query);
            }

            return .{ .impl = impl };
        }

        /// The fixed-buffer `std.mem.Allocator`. Allocations come from the
        /// caller's buffer; the zone meters its retained `end_index`.
        pub fn allocator(self: *Self) Allocator {
            _ = self.implOrPanic();
            return .{
                .ptr = self.impl.?,
                .vtable = &.{
                    .alloc = Self.allocFn,
                    .resize = Self.resizeFn,
                    .remap = Self.remapFn,
                    .free = Self.freeFn,
                },
            };
        }

        pub fn currentBytes(self: *const Self) usize {
            if (comptime !ZoneDef.capabilities.stats) return 0;
            return self.implOrPanic().zone_state.currentBytes();
        }
        pub fn peakBytes(self: *const Self) usize {
            if (comptime !ZoneDef.capabilities.stats) return 0;
            return self.implOrPanic().zone_state.peakBytes();
        }
        pub fn allocationCount(self: *const Self) usize {
            if (comptime !ZoneDef.capabilities.stats) return 0;
            return self.implOrPanic().zone_state.allocationCount();
        }
        pub fn deallocationCount(self: *const Self) usize {
            if (comptime !ZoneDef.capabilities.stats) return 0;
            return self.implOrPanic().zone_state.deallocationCount();
        }
        pub fn budgetPercent(self: *const Self) f32 {
            if (comptime !ZoneDef.capabilities.stats) return 0;
            return self.implOrPanic().zone_state.budgetPercent();
        }
        pub fn hardcapPercent(self: *const Self) f32 {
            if (comptime !ZoneDef.capabilities.stats) return 0;
            return self.implOrPanic().zone_state.hardcapPercent();
        }
        pub fn zoneName(self: *const Self) []const u8 {
            _ = self;
            return ZoneDef.zone_name;
        }
        pub fn markFrame(self: *Self) void {
            if (comptime !ZoneDef.capabilities.stats) return;
            self.implOrPanic().zone_state.markFrame();
        }
        pub fn frameDelta(self: *const Self) i64 {
            if (comptime !ZoneDef.capabilities.stats) return 0;
            return self.implOrPanic().zone_state.frameDelta();
        }
        pub fn frameAllocs(self: *const Self) usize {
            if (comptime !ZoneDef.capabilities.stats) return 0;
            return self.implOrPanic().zone_state.frameAllocs();
        }
        pub fn frameFrees(self: *const Self) usize {
            if (comptime !ZoneDef.capabilities.stats) return 0;
            return self.implOrPanic().zone_state.frameFrees();
        }

        /// Rewind the buffer to empty and zero the retained footprint. Cumulative
        /// lifetime stats survive: a reset is a bulk free, so the free count is
        /// caught up to the alloc count to keep the deinit call-balance honest.
        pub fn reset(self: *Self) void {
            const impl = self.implOrPanic();
            impl.fba.reset();
            if (comptime ZoneDef.capabilities.stats) {
                impl.zone_state.tracked.setCurrentBytes(0);
                // Reset is a bulk free: frees catch up to allocs so the
                // deinit counter-balance check passes; cumulative allocation
                // count is preserved.
                impl.zone_state.tracked.setDeallocationCount(impl.zone_state.tracked.allocationCount());
            }
        }

        /// Whether `ptr` points into this wrapper's buffer.
        pub fn ownsPtr(self: *Self, ptr: [*]u8) bool {
            return self.implOrPanic().fba.ownsPtr(ptr);
        }

        /// Whether `slice` lies within this wrapper's buffer.
        pub fn ownsSlice(self: *Self, slice: []u8) bool {
            return self.implOrPanic().fba.ownsSlice(slice);
        }

        /// Whether `slice` is the most recent allocation -- the only one a free
        /// can rewind, since the buffer is bump-allocated.
        pub fn isLastAllocation(self: *Self, slice: []u8) bool {
            return self.implOrPanic().fba.isLastAllocation(slice);
        }

        /// Tear down the wrapper. Reports `.leak` from an alloc/free *call*
        /// imbalance, not from `currentBytes != 0` -- non-LIFO frees leave
        /// retained footprint without being a leak. Frees the wrapper on its
        /// control allocator; the caller's buffer is untouched.
        pub fn deinit(self: *Self) Runtime.DeinitStatus {
            const impl = self.impl orelse @panic("gdt-ledger: double deinit");
            if (comptime ZoneDef.capabilities.runtime_export) {
                if (lifecycle.hasLiveChildren(&impl.runtime.lifecycle_header)) return .live_children;
            }

            // NOTE(accounting): leak = unbalanced alloc/free CALLS, not
            // currentBytes != 0 -- FixedBufferAllocator only rewinds
            // end_index for the last allocation, so a program that freed
            // everything in non-LIFO order still has a nonzero retained
            // footprint that must not be reported as .leak.
            // currentBytes keeps end_index (retained footprint) semantics.
            const leaked = if (comptime ZoneDef.capabilities.stats)
                self.allocationCount() != self.deallocationCount()
            else
                false;
            if (comptime ZoneDef.capabilities.runtime_export) {
                Runtime.unlink(&impl.runtime.runtime_export);
            }

            const control_allocator = controlAllocator(impl);
            control_allocator.destroy(impl);
            self.impl = null;

            return if (leaked) .leak else .ok;
        }

        fn implOrPanic(self: *const Self) *Impl {
            return self.impl orelse @panic("gdt-ledger: use after deinit");
        }

        fn controlAllocator(impl: *const Impl) Allocator {
            return if (comptime ZoneDef.capabilities.runtime_export)
                impl.runtime.lifecycle_header.control_allocator
            else
                impl.runtime.control_allocator;
        }

        // Build a ZoneInfo snapshot for the runtime registry. Always a root
        // (parent_id null): this wrapper has no subzones.
        fn query(ctx: *const anyopaque) ZoneInfo {
            const impl: *const Impl = @ptrCast(@alignCast(ctx));
            return .{
                .id = @intFromPtr(&impl.runtime.runtime_export),
                .parent_id = null,
                .name = ZoneDef.zone_name,
                .local_name = ZoneDef.zone_local_name,
                .parent_name = ZoneDef.parent_name,
                .depth = ZoneDef.depth,
                .current_bytes = impl.zone_state.currentBytes(),
                .peak_bytes = impl.zone_state.peakBytes(),
                .allocation_count = impl.zone_state.allocationCount(),
                .deallocation_count = impl.zone_state.deallocationCount(),
                .budget = ZoneDef.config.budget,
                .budget_percent = impl.zone_state.budgetPercent(),
                .hardcap = ZoneDef.config.hardcap,
                .hardcap_percent = impl.zone_state.hardcapPercent(),
                .frame_delta = impl.zone_state.frameDelta(),
                .frame_allocs = impl.zone_state.frameAllocs(),
                .frame_frees = impl.zone_state.frameFrees(),
            };
        }

        fn allocFn(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const impl: *Impl = @ptrCast(@alignCast(ctx));
            const old_end_index = impl.fba.end_index;
            const result = std.heap.FixedBufferAllocator.alloc(&impl.fba, len, alignment, ret_addr) orelse return null;

            if (comptime ZoneDef.capabilities.stats) {
                if (comptime ZoneDef.capabilities.hardcap) {
                    // NOTE(accounting): the cap meters end_index -- retained
                    // footprint including alignment padding and unrewound
                    // frees -- NOT live requested bytes like Zone's hardcap.
                    // Same config field, different unit; inherent to FBA.
                    if (impl.fba.end_index > ZoneDef.config.hardcap) {
                        impl.fba.end_index = old_end_index;
                        return null;
                    }
                }

                impl.zone_state.tracked.setCurrentBytes(impl.fba.end_index);
                impl.zone_state.tracked.incrementAllocationCount();
            }

            return result;
        }

        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            const impl: *Impl = @ptrCast(@alignCast(ctx));
            const old_end_index = impl.fba.end_index;

            if (!std.heap.FixedBufferAllocator.resize(&impl.fba, memory, alignment, new_len, ret_addr)) return false;

            if (comptime ZoneDef.capabilities.stats) {
                if (comptime ZoneDef.capabilities.hardcap) {
                    if (impl.fba.end_index > ZoneDef.config.hardcap) {
                        impl.fba.end_index = old_end_index;
                        return false;
                    }
                }

                impl.zone_state.tracked.setCurrentBytes(impl.fba.end_index);
            }

            return true;
        }

        fn remapFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const impl: *Impl = @ptrCast(@alignCast(ctx));
            const old_end_index = impl.fba.end_index;
            const result = std.heap.FixedBufferAllocator.remap(&impl.fba, memory, alignment, new_len, ret_addr) orelse return null;

            if (comptime ZoneDef.capabilities.stats) {
                if (comptime ZoneDef.capabilities.hardcap) {
                    if (impl.fba.end_index > ZoneDef.config.hardcap) {
                        impl.fba.end_index = old_end_index;
                        return null;
                    }
                }

                impl.zone_state.tracked.setCurrentBytes(impl.fba.end_index);
            }

            return result;
        }

        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const impl: *Impl = @ptrCast(@alignCast(ctx));
            std.heap.FixedBufferAllocator.free(&impl.fba, memory, alignment, ret_addr);

            if (comptime ZoneDef.capabilities.stats) {
                // Every free() call counts, whether or not FBA could rewind
                // end_index -- the deinit leak check balances calls, and an
                // end_index-gated count would structurally undercount
                // non-LIFO frees.
                impl.zone_state.tracked.incrementDeallocationCount();
                impl.zone_state.tracked.setCurrentBytes(impl.fba.end_index);
            }
        }
    };
}

test "zoned fixed buffer tracks actual buffer usage" {
    var buffer: [128]u8 = undefined;
    const Zone = @import("../zone/root.zig").Zone(.{ .name = "fba" });
    if (!Zone.capabilities.stats) return error.SkipZigTest;

    const Wrapped = ZonedFixedBuffer(Zone);
    var wrapped = try Wrapped.init(.{
        .buffer = &buffer,
        .control_allocator = std.testing.allocator,
    });
    const ally = wrapped.allocator();

    const a = try ally.alloc(u8, 24);
    const b = try ally.alloc(u8, 16);
    try std.testing.expect(wrapped.currentBytes() >= 40);

    ally.free(a);
    // Non-last free can't rewind end_index, but the call still counts.
    try std.testing.expect(wrapped.currentBytes() >= 40);
    try std.testing.expectEqual(@as(usize, 1), wrapped.deallocationCount());

    ally.free(b);
    try std.testing.expect(wrapped.currentBytes() >= 24);
    try std.testing.expectEqual(@as(usize, 2), wrapped.deallocationCount());

    // Everything was freed (non-LIFO): no leak despite retained footprint.
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, wrapped.deinit());
}

test "fixed buffer deinit reports a real leak via counter balance" {
    var buffer: [128]u8 = undefined;
    const Zone = @import("../zone/root.zig").Zone(.{ .name = "fba_leak" });
    if (!Zone.capabilities.stats) return error.SkipZigTest;

    const Wrapped = ZonedFixedBuffer(Zone);
    var wrapped = try Wrapped.init(.{
        .buffer = &buffer,
        .control_allocator = std.testing.allocator,
    });
    const ally = wrapped.allocator();

    _ = try ally.alloc(u8, 32);
    try std.testing.expectEqual(Runtime.DeinitStatus.leak, wrapped.deinit());
}

test "zoned fixed buffer reset clears usage and deinit checks leak" {
    var buffer: [128]u8 = undefined;
    const Zone = @import("../zone/root.zig").Zone(.{ .name = "fba_reset", .hardcap = 80 });
    if (!Zone.capabilities.stats) return error.SkipZigTest;

    const Wrapped = ZonedFixedBuffer(Zone);
    var wrapped = try Wrapped.init(.{
        .buffer = &buffer,
        .control_allocator = std.testing.allocator,
    });
    const ally = wrapped.allocator();

    _ = try ally.alloc(u8, 32);
    try std.testing.expect(wrapped.currentBytes() > 0);

    wrapped.reset();
    try std.testing.expectEqual(@as(usize, 0), wrapped.currentBytes());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, wrapped.deinit());
}

test "reset preserves cumulative lifetime stats" {
    var buffer: [256]u8 = undefined;
    const Zone = @import("../zone/root.zig").Zone(.{ .name = "fba_cumulative" });
    if (!Zone.capabilities.stats) return error.SkipZigTest;

    const Wrapped = ZonedFixedBuffer(Zone);
    var wrapped = try Wrapped.init(.{
        .buffer = &buffer,
        .control_allocator = std.testing.allocator,
    });
    const ally = wrapped.allocator();

    _ = try ally.alloc(u8, 32);
    _ = try ally.alloc(u8, 64);
    const pre_reset_allocs = wrapped.allocationCount();
    const pre_reset_peak = wrapped.peakBytes();

    wrapped.reset();

    try std.testing.expectEqual(@as(usize, 0), wrapped.currentBytes());
    try std.testing.expectEqual(pre_reset_allocs, wrapped.allocationCount());
    try std.testing.expect(wrapped.peakBytes() >= pre_reset_peak);

    try std.testing.expectEqual(Runtime.DeinitStatus.ok, wrapped.deinit());
}

test "hardcap failure rolls back fixed-buffer alignment padding" {
    // NOTE(align): the buffer must be 16-aligned so the u128-aligned alloc at
    // end_index 1 deterministically needs 15 bytes of padding (1+15+1 > cap).
    // With natural [128]u8 alignment the test outcome depended on the stack
    // address: base == 15 (mod 16) makes the padding zero and the alloc fit.
    var buffer: [128]u8 align(16) = undefined;
    const Zone = @import("../zone/root.zig").Zone(.{ .name = "fba_align_rollback", .hardcap = 16 });
    if (!Zone.capabilities.hardcap) return error.SkipZigTest;

    const Wrapped = ZonedFixedBuffer(Zone);
    var wrapped = try Wrapped.init(.{
        .buffer = &buffer,
        .control_allocator = std.testing.allocator,
    });
    const ally = wrapped.allocator();

    const first = try ally.alloc(u8, 1);
    try std.testing.expectEqual(@as(usize, 1), wrapped.currentBytes());

    try std.testing.expectError(error.OutOfMemory, ally.alignedAlloc(u8, .of(u128), 1));
    try std.testing.expectEqual(@as(usize, 1), wrapped.currentBytes());

    const rest = try ally.alloc(u8, 15);
    try std.testing.expectEqual(@as(usize, 16), wrapped.currentBytes());

    ally.free(rest);
    ally.free(first);
    wrapped.reset();
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, wrapped.deinit());
}
