//! `std.mem.Allocator` adapter that meters every call, then forwards it to a
//! backing allocator.
//!
//! `TrackedAllocator(config)` generates two types around a `Meter`:
//! - `State`: the durable counter storage. The allocator vtable points at it, so
//!   it must stay at a fixed address while in use -- embed it where it outlives
//!   every allocation it tracks.
//! - `Promoted`: a `State` bound to one backing allocator, exposing the
//!   `Allocator` interface. Keeping the two apart lets `State` stay movable
//!   until promotion pins it.
//!
//! Each allocation path reserves against the hardcap first, calls the backing
//! allocator, then commits or rolls back, so a backing failure never leaves
//! reserved bytes counted. The overflow-safe hardcap math lives in `Meter`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Meter = @import("meter.zig").Meter;
const TrackedConfig = @import("../config/tracked.zig");

/// Generate the tracked-allocator types for `config`. Hardcap enforcement reads
/// the live-byte counter, so `enable_memory_limit` without `enable_stats` is a
/// `@compileError`.
pub fn TrackedAllocator(comptime config: TrackedConfig) type {
    comptime {
        if (config.enable_memory_limit and !config.enable_stats) {
            @compileError("TrackedAllocator: enable_memory_limit requires enable_stats (current_bytes needed for limit checks)");
        }
    }

    const MeterState = Meter(.{
        .stats = config.enable_stats,
        .hardcap = config.enable_memory_limit,
        .frames = false,
        .lifecycle = false,
        .runtime_export = false,
    }, config.thread_safe);

    return struct {
        /// A `State` bound to one backing allocator. Hand out its `allocator()`
        /// and every call is metered against the shared `State`, then forwarded
        /// to the backing allocator. The stat accessors and setters mirror
        /// `State`'s (and ultimately the meter's), returning 0 / no-op when the
        /// matching capability is compiled out.
        pub const Promoted = struct {
            backing_allocator: Allocator,
            state: *State,

            const PromotedSelf = @This();

            /// Build the `std.mem.Allocator` interface. The returned allocator
            /// borrows `self`, which must outlive it and stay at this address.
            pub fn allocator(self: *PromotedSelf) Allocator {
                return .{
                    .ptr = self,
                    .vtable = &.{
                        .alloc = PromotedSelf.allocFn,
                        .resize = PromotedSelf.resizeFn,
                        .remap = PromotedSelf.remapFn,
                        .free = PromotedSelf.freeFn,
                    },
                };
            }

            pub fn currentBytes(self: *const PromotedSelf) usize {
                return self.state.currentBytes();
            }

            pub fn peakBytes(self: *const PromotedSelf) usize {
                return self.state.peakBytes();
            }

            pub fn allocationCount(self: *const PromotedSelf) usize {
                return self.state.allocationCount();
            }

            pub fn deallocationCount(self: *const PromotedSelf) usize {
                return self.state.deallocationCount();
            }

            pub fn setMemoryLimit(self: *PromotedSelf, limit: usize) void {
                self.state.setMemoryLimit(limit);
            }

            pub fn rawAlloc(self: *PromotedSelf, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
                return self.state.rawAlloc(self.backing_allocator, len, alignment, ret_addr);
            }

            pub fn rawResize(self: *PromotedSelf, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
                return self.state.rawResize(self.backing_allocator, memory, alignment, new_len, ret_addr);
            }

            pub fn rawRemap(self: *PromotedSelf, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
                return self.state.rawRemap(self.backing_allocator, memory, alignment, new_len, ret_addr);
            }

            pub fn rawFree(self: *PromotedSelf, memory: []u8, alignment: Alignment, ret_addr: usize) void {
                self.state.rawFree(self.backing_allocator, memory, alignment, ret_addr);
            }

            fn allocFn(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
                const self: *PromotedSelf = @ptrCast(@alignCast(ctx));
                return self.rawAlloc(len, alignment, ret_addr);
            }

            fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
                const self: *PromotedSelf = @ptrCast(@alignCast(ctx));
                return self.rawResize(memory, alignment, new_len, ret_addr);
            }

            fn remapFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
                const self: *PromotedSelf = @ptrCast(@alignCast(ctx));
                return self.rawRemap(memory, alignment, new_len, ret_addr);
            }

            fn freeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
                const self: *PromotedSelf = @ptrCast(@alignCast(ctx));
                self.rawFree(memory, alignment, ret_addr);
            }
        };

        /// Durable counter storage: a single embedded `Meter`. Pin it where it
        /// outlives every allocation, then `promote` it to allocate. The stat
        /// accessors (`currentBytes`, `peakBytes`, `allocationCount`,
        /// `deallocationCount`) and setters forward to the meter and return 0 /
        /// no-op when the matching capability is compiled out.
        pub const State = struct {
            meter: MeterState = .{},

            const StateSelf = @This();

            /// Bind this state to `backing_allocator`, returning a `Promoted`
            /// that exposes the `Allocator` interface. The state keeps living
            /// here; `Promoted` only holds a pointer back to it.
            pub fn promote(self: *StateSelf, backing_allocator: Allocator) Promoted {
                return .{
                    .backing_allocator = backing_allocator,
                    .state = self,
                };
            }

            pub fn currentBytes(self: *const StateSelf) usize {
                return self.meter.currentBytes();
            }

            pub fn peakBytes(self: *const StateSelf) usize {
                return self.meter.peakBytes();
            }

            pub fn allocationCount(self: *const StateSelf) usize {
                return self.meter.allocationCount();
            }

            pub fn deallocationCount(self: *const StateSelf) usize {
                return self.meter.deallocationCount();
            }

            pub fn setMemoryLimit(self: *StateSelf, limit: usize) void {
                self.meter.setMemoryLimit(limit);
            }

            pub fn setCurrentBytes(self: *StateSelf, current: usize) void {
                self.meter.setCurrentBytes(current);
            }

            /// Lower the peak high-water to the current live-byte total, so a
            /// later `peakBytes` reflects only allocations after this call. For
            /// per-window peak measurement on a single-owner tracker. No-op when
            /// stats are compiled out.
            pub fn resetPeak(self: *StateSelf) void {
                self.meter.resetPeak();
            }

            pub fn incrementAllocationCount(self: *StateSelf) void {
                self.meter.incrementAllocationCount();
            }

            pub fn incrementDeallocationCount(self: *StateSelf) void {
                self.meter.incrementDeallocationCount();
            }

            pub fn setDeallocationCount(self: *StateSelf, count: usize) void {
                self.meter.setDeallocationCount(count);
            }

            /// Metered allocation: reserve against the hardcap, call the backing
            /// allocator, then commit. Returns null without touching the backing
            /// allocator if the reservation is refused; if the backing allocator
            /// fails, the reservation is rolled back, so a failed alloc never
            /// leaves bytes counted.
            pub fn rawAlloc(self: *StateSelf, backing_allocator: Allocator, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
                const reserved = self.meter.tryReserve(len) orelse return null;

                const result = backing_allocator.rawAlloc(len, alignment, ret_addr) orelse {
                    self.meter.rollbackReserve(len);
                    return null;
                };

                self.meter.commitAlloc(len, reserved);

                return result;
            }

            /// Metered in-place resize. Growth reserves the delta first and rolls
            /// back if the backing resize fails; shrink commits the delta with no
            /// reservation. Returns false (counters unchanged) when the backing
            /// allocator cannot resize in place.
            pub fn rawResize(self: *StateSelf, backing_allocator: Allocator, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
                if (new_len > memory.len) {
                    const delta = new_len - memory.len;

                    const reserved = self.meter.tryReserve(delta) orelse return false;

                    if (!backing_allocator.rawResize(memory, alignment, new_len, ret_addr)) {
                        self.meter.rollbackReserve(delta);
                        return false;
                    }

                    self.meter.commitResize(memory.len, new_len, reserved);
                } else {
                    if (!backing_allocator.rawResize(memory, alignment, new_len, ret_addr)) return false;

                    self.meter.commitResize(memory.len, new_len, 0);
                }

                return true;
            }

            /// Metered remap. Accounts like `rawResize`, but the backing
            /// allocator may return a moved pointer. Null means the remap failed
            /// (a growth reservation is already rolled back).
            pub fn rawRemap(self: *StateSelf, backing_allocator: Allocator, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
                if (new_len > memory.len) {
                    const delta = new_len - memory.len;

                    const reserved = self.meter.tryReserve(delta) orelse return null;

                    const result = backing_allocator.rawRemap(memory, alignment, new_len, ret_addr) orelse {
                        self.meter.rollbackReserve(delta);
                        return null;
                    };

                    self.meter.commitResize(memory.len, new_len, reserved);

                    return result;
                }

                const result = backing_allocator.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
                self.meter.commitResize(memory.len, new_len, 0);

                return result;
            }

            /// Metered free: commit the freed bytes, then release them through
            /// the backing allocator.
            pub fn rawFree(self: *StateSelf, backing_allocator: Allocator, memory: []u8, alignment: Alignment, ret_addr: usize) void {
                self.meter.commitFree(memory.len);
                backing_allocator.rawFree(memory, alignment, ret_addr);
            }
        };
    };
}

// ============================================================
// Tests
// ============================================================

test "basic alloc/free tracks stats" {
    const Tracked = TrackedAllocator(.{});
    var state: Tracked.State = .{};
    var promoted = state.promote(std.testing.allocator);
    const ally = promoted.allocator();

    const slice = try ally.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), state.currentBytes());
    try std.testing.expectEqual(@as(usize, 100), state.peakBytes());
    try std.testing.expectEqual(@as(usize, 1), state.allocationCount());

    ally.free(slice);
    try std.testing.expectEqual(@as(usize, 0), state.currentBytes());
    try std.testing.expectEqual(@as(usize, 100), state.peakBytes());
    try std.testing.expectEqual(@as(usize, 1), state.allocationCount());
}

test "state promotion mutates shared state" {
    const Tracked = TrackedAllocator(.{});
    var state: Tracked.State = .{};
    var promoted = state.promote(std.testing.allocator);
    const ally = promoted.allocator();

    const slice = try ally.alloc(u8, 64);
    try std.testing.expectEqual(@as(usize, 64), state.currentBytes());

    ally.free(slice);
    try std.testing.expectEqual(@as(usize, 0), state.currentBytes());
}

test "multiple allocs accumulate" {
    const Tracked = TrackedAllocator(.{});
    var state: Tracked.State = .{};
    var promoted = state.promote(std.testing.allocator);
    const ally = promoted.allocator();

    const a = try ally.alloc(u8, 50);
    const b = try ally.alloc(u8, 75);
    try std.testing.expectEqual(@as(usize, 125), state.currentBytes());
    try std.testing.expectEqual(@as(usize, 2), state.allocationCount());

    ally.free(a);
    try std.testing.expectEqual(@as(usize, 75), state.currentBytes());
    try std.testing.expectEqual(@as(usize, 125), state.peakBytes());

    ally.free(b);
    try std.testing.expectEqual(@as(usize, 0), state.currentBytes());
}

test "resize updates stats" {
    const Tracked = TrackedAllocator(.{});
    var state: Tracked.State = .{};
    var promoted = state.promote(std.testing.allocator);
    const ally = promoted.allocator();

    var slice = try ally.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), state.currentBytes());

    if (ally.resize(slice, 200)) {
        slice = slice.ptr[0..200];
        try std.testing.expectEqual(@as(usize, 200), state.currentBytes());
    }

    ally.free(slice);
    try std.testing.expectEqual(@as(usize, 0), state.currentBytes());
}

test "resize/remap accounting is deterministic against a FixedBufferAllocator" {
    // testing.allocator rarely grows in place, so the in-place paths above
    // are usually skipped -- FBA makes grow/shrink/remap of the last
    // allocation deterministic.
    var buffer: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const backing = fba.allocator();

    const Tracked = TrackedAllocator(.{});
    var state: Tracked.State = .{};
    var promoted = state.promote(backing);
    const ally = promoted.allocator();

    var slice = try ally.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), state.currentBytes());
    try std.testing.expectEqual(@as(usize, 100), state.peakBytes());

    // In-place grow (last allocation): delta added, peak follows.
    try std.testing.expect(ally.resize(slice, 150));
    slice = slice.ptr[0..150];
    try std.testing.expectEqual(@as(usize, 150), state.currentBytes());
    try std.testing.expectEqual(@as(usize, 150), state.peakBytes());

    // In-place shrink: delta subtracted, peak untouched.
    try std.testing.expect(ally.resize(slice, 50));
    slice = slice.ptr[0..50];
    try std.testing.expectEqual(@as(usize, 50), state.currentBytes());
    try std.testing.expectEqual(@as(usize, 150), state.peakBytes());

    // Failed grow (beyond buffer capacity): counters untouched.
    try std.testing.expect(!ally.resize(slice, 1000));
    try std.testing.expectEqual(@as(usize, 50), state.currentBytes());
    try std.testing.expectEqual(@as(usize, 150), state.peakBytes());

    // Remap grow (FBA remaps in place for the last allocation).
    const remapped = ally.remap(slice, 80) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 80), state.currentBytes());
    try std.testing.expectEqual(@as(usize, 150), state.peakBytes());

    ally.free(remapped);
    try std.testing.expectEqual(@as(usize, 0), state.currentBytes());
    try std.testing.expectEqual(@as(usize, 1), state.allocationCount());
    try std.testing.expectEqual(@as(usize, 1), state.deallocationCount());
}

test "stats disabled returns zero" {
    const Tracked = TrackedAllocator(.{ .enable_stats = false });
    var state: Tracked.State = .{};
    var promoted = state.promote(std.testing.allocator);
    const ally = promoted.allocator();

    const slice = try ally.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 0), state.currentBytes());
    try std.testing.expectEqual(@as(usize, 0), state.peakBytes());
    try std.testing.expectEqual(@as(usize, 0), state.allocationCount());

    ally.free(slice);
}

test "memory limit rejects over-budget allocs" {
    const Tracked = TrackedAllocator(.{ .enable_memory_limit = true });
    var state: Tracked.State = .{};
    state.setMemoryLimit(200);
    var promoted = state.promote(std.testing.allocator);
    const ally = promoted.allocator();

    const a = try ally.alloc(u8, 150);
    try std.testing.expectEqual(@as(usize, 150), state.currentBytes());

    try std.testing.expectError(error.OutOfMemory, ally.alloc(u8, 100));

    ally.free(a);
}

test "single-threaded mode compiles" {
    const Tracked = TrackedAllocator(.{ .thread_safe = false });
    var state: Tracked.State = .{};
    var promoted = state.promote(std.testing.allocator);
    const ally = promoted.allocator();

    const slice = try ally.alloc(u8, 64);
    try std.testing.expectEqual(@as(usize, 64), state.currentBytes());
    ally.free(slice);
    try std.testing.expectEqual(@as(usize, 0), state.currentBytes());
}

test "void elimination -- stats disabled shrinks struct" {
    const WithStats = TrackedAllocator(.{ .enable_stats = true, .enable_memory_limit = false });
    const NoStats = TrackedAllocator(.{ .enable_stats = false, .enable_memory_limit = false });
    try std.testing.expect(@sizeOf(NoStats.State) < @sizeOf(WithStats.State));
}

test "void elimination -- memory limit disabled shrinks struct" {
    const WithLimit = TrackedAllocator(.{ .enable_memory_limit = true });
    const NoLimit = TrackedAllocator(.{ .enable_memory_limit = false });
    try std.testing.expect(@sizeOf(NoLimit.State) < @sizeOf(WithLimit.State));
}

test "multi-threaded stress -- stats consistent" {
    const Tracked = TrackedAllocator(.{ .thread_safe = true });
    var state: Tracked.State = .{};
    var promoted = state.promote(std.testing.allocator);
    const ally = promoted.allocator();

    const thread_count = 8;
    const allocs_per_thread = 1000;
    const alloc_size = 64;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn worker(a: Allocator) void {
                var slices: [allocs_per_thread][]u8 = undefined;

                for (&slices) |*s| {
                    s.* = a.alloc(u8, alloc_size) catch @panic("alloc failed");
                }

                for (slices) |s| {
                    a.free(s);
                }
            }
        }.worker, .{ally});
    }

    for (&threads) |*t| t.join();

    try std.testing.expectEqual(@as(usize, 0), state.currentBytes());
    try std.testing.expect(state.peakBytes() <= thread_count * allocs_per_thread * alloc_size);
    try std.testing.expectEqual(@as(usize, thread_count * allocs_per_thread), state.allocationCount());
    try std.testing.expectEqual(@as(usize, thread_count * allocs_per_thread), state.deallocationCount());
}

test "resetPeak isolates a per-window peak" {
    const Tracked = TrackedAllocator(.{});
    var state: Tracked.State = .{};
    var promoted = state.promote(std.testing.allocator);
    const ally = promoted.allocator();

    // Window A: grow to 1000 live, then free it all.
    const a = try ally.alloc(u8, 1000);
    try std.testing.expectEqual(@as(usize, 1000), state.peakBytes());
    ally.free(a);
    try std.testing.expectEqual(@as(usize, 0), state.currentBytes());

    // Reset drops the high-water to the current live bytes (0 here).
    state.resetPeak();
    try std.testing.expectEqual(@as(usize, 0), state.peakBytes());

    // Window B: a smaller peak is not polluted by A's 1000.
    const b = try ally.alloc(u8, 200);
    try std.testing.expectEqual(@as(usize, 200), state.peakBytes());
    ally.free(b);
}

test "deallocation count tracks frees" {
    const Tracked = TrackedAllocator(.{});
    var state: Tracked.State = .{};
    var promoted = state.promote(std.testing.allocator);
    const ally = promoted.allocator();

    const a = try ally.alloc(u8, 50);
    const b = try ally.alloc(u8, 75);
    const c = try ally.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 3), state.allocationCount());
    try std.testing.expectEqual(@as(usize, 0), state.deallocationCount());

    ally.free(a);
    ally.free(b);
    try std.testing.expectEqual(@as(usize, 3), state.allocationCount());
    try std.testing.expectEqual(@as(usize, 2), state.deallocationCount());

    ally.free(c);
    try std.testing.expectEqual(@as(usize, 3), state.allocationCount());
    try std.testing.expectEqual(@as(usize, 3), state.deallocationCount());
}
