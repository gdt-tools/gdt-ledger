//! `ZoneCore`: the heap-allocated implementation behind a metered zone.
//!
//! Composes the pieces a `.full`/`.guardrails` zone needs: a `TrackedAllocator`
//! for byte/count metering, `FrameStats` for per-frame deltas, a lifecycle
//! `Header` for parent/child attachment and leak detection, and -- under `.full`
//! -- a runtime `Export` node so dumps can see the zone. `zone/root.zig` owns
//! the public handle and forwards to the methods here; the `.off` zone shape
//! never instantiates this.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const frames = @import("frames.zig");
const lifecycle = @import("lifecycle.zig");
const Runtime = @import("../runtime/root.zig");
const TrackedConfig = @import("../config/tracked.zig");
const TrackedAllocator = @import("../accounting/tracked_allocator.zig").TrackedAllocator;
const ZoneInfo = Runtime.ZoneInfo;

/// The links a child captures from its parent at init: the parent's lifecycle
/// header (for attachment and live-child tracking) and, under `.full`, its
/// runtime export node (for the dump hierarchy). Either may be null.
pub const ParentRef = struct {
    lifecycle: ?*lifecycle.Header,
    runtime_export: ?*Runtime.Export,
};

/// Generate the core impl type for a resolved zone definition `Def`. Wires the
/// tracked allocator, frame stats, and -- per `Def.capabilities` -- the runtime
/// export node, using `Def.config` for the hardcap, budget, and thread-safety.
pub fn ZoneCore(comptime Def: type) type {
    const tracked_config = TrackedConfig{
        .enable_memory_limit = Def.capabilities.hardcap,
        .enable_stats = Def.capabilities.stats,
        .thread_safe = Def.config.thread_safe,
    };

    const TrackedType = TrackedAllocator(tracked_config);
    const FrameStats = frames.FrameStats(Def.capabilities.frames, Def.config.thread_safe);

    return struct {
        lifecycle_header: lifecycle.Header,
        runtime_export: if (Def.capabilities.runtime_export) Runtime.Export else void,
        backing_allocator: Allocator,
        // NOTE(ownership): the app-owned allocator at the top of this zone's
        // chain, threaded down through every initUnder. Off subzones capture
        // it BY VALUE instead of parent.allocator() -- the parent's vtable ctx
        // dies with the parent impl, the root backing outlives every zone
        // (use-after-free otherwise). Wrapper-internal zones are their own root: an off
        // subzone reached in under a ZonedArena/ZonedDebug captures the
        // wrapper-owned allocator and must not outlive the wrapper.
        root_backing: Allocator,
        state: State = .{},

        const Self = @This();

        /// The metered state embedded in the core: the tracked allocator's
        /// counters plus the frame-delta accumulator. The vtable forwards every
        /// `raw*` call here; the stat accessors mirror the tracked allocator's.
        pub const State = struct {
            tracked: TrackedType.State = blk: {
                var tracked_state: TrackedType.State = .{};
                if (tracked_config.enable_memory_limit) tracked_state.setMemoryLimit(Def.config.hardcap);
                break :blk tracked_state;
            },
            frame_stats: FrameStats = .{},

            const StateSelf = @This();

            pub fn currentBytes(self: *const StateSelf) usize {
                return self.tracked.currentBytes();
            }

            pub fn peakBytes(self: *const StateSelf) usize {
                return self.tracked.peakBytes();
            }

            pub fn allocationCount(self: *const StateSelf) usize {
                return self.tracked.allocationCount();
            }

            pub fn deallocationCount(self: *const StateSelf) usize {
                return self.tracked.deallocationCount();
            }

            /// Live bytes as a percentage of the configured budget. Returns 0
            /// when stats are off or no budget is set, and may exceed 100 -- a
            /// budget is a gauge, not a ceiling.
            pub fn budgetPercent(self: *const StateSelf) f32 {
                if (!Def.capabilities.stats or Def.config.budget == 0) return 0;
                return @as(f32, @floatFromInt(self.currentBytes())) /
                    @as(f32, @floatFromInt(Def.config.budget)) * 100.0;
            }

            /// Live bytes as a percentage of the hardcap. Returns 0 when the
            /// hardcap is off or unset.
            pub fn hardcapPercent(self: *const StateSelf) f32 {
                if (!Def.capabilities.hardcap or Def.config.hardcap == 0) return 0;
                return @as(f32, @floatFromInt(self.currentBytes())) /
                    @as(f32, @floatFromInt(Def.config.hardcap)) * 100.0;
            }

            /// Sample the live totals into the frame accumulator as the new
            /// baseline; the `frame*` readers then report against it.
            pub fn markFrame(self: *StateSelf) void {
                const current = self.currentBytes();
                const allocs = self.allocationCount();
                const frees = self.deallocationCount();
                self.frame_stats.mark(current, allocs, frees);
            }

            pub fn frameDelta(self: *const StateSelf) i64 {
                return self.frame_stats.frameDelta();
            }

            pub fn frameAllocs(self: *const StateSelf) usize {
                return self.frame_stats.frameAllocs();
            }

            pub fn frameFrees(self: *const StateSelf) usize {
                return self.frame_stats.frameFrees();
            }

            pub fn rawAlloc(self: *StateSelf, backing_allocator: Allocator, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
                return self.tracked.rawAlloc(backing_allocator, len, alignment, ret_addr);
            }

            pub fn rawResize(self: *StateSelf, backing_allocator: Allocator, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
                return self.tracked.rawResize(backing_allocator, memory, alignment, new_len, ret_addr);
            }

            pub fn rawRemap(self: *StateSelf, backing_allocator: Allocator, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
                return self.tracked.rawRemap(backing_allocator, memory, alignment, new_len, ret_addr);
            }

            pub fn rawFree(self: *StateSelf, backing_allocator: Allocator, memory: []u8, alignment: Alignment, ret_addr: usize) void {
                self.tracked.rawFree(backing_allocator, memory, alignment, ret_addr);
            }
        };

        /// Allocate and initialize a core on `control_allocator`. Records the
        /// backing and root-backing allocators, sets up the lifecycle header
        /// (attaching to `parent` when given), and under `.full` links a runtime
        /// export node so dumps can reach it. When export is on it first checks
        /// that the app declared runtime storage (`Runtime.requireRuntime`).
        ///
        /// # Errors
        /// `error.OutOfMemory` if `control_allocator` cannot allocate the core.
        pub fn create(backing_allocator: Allocator, control_allocator: Allocator, root_backing: Allocator, parent: ?ParentRef) !*Self {
            if (Def.capabilities.runtime_export) Runtime.requireRuntime();

            const self = try control_allocator.create(Self);
            errdefer control_allocator.destroy(self);

            lifecycle.init(&self.lifecycle_header, control_allocator, if (parent) |p| p.lifecycle else null);
            self.backing_allocator = backing_allocator;
            self.root_backing = root_backing;
            self.state = .{};

            lifecycle.attachToParent(&self.lifecycle_header);
            if (comptime Def.capabilities.runtime_export) {
                Runtime.initExport(&self.runtime_export, if (parent) |p| p.runtime_export else null);
                Runtime.link(&self.runtime_export, self, &query);
            }

            return self;
        }

        /// The metered `std.mem.Allocator`. Its vtable ctx is this core, so the
        /// core must stay at a fixed address while the allocator is in use; it
        /// lives on the control allocator's heap, which satisfies that.
        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = allocFn,
                    .resize = resizeFn,
                    .remap = remapFn,
                    .free = freeFn,
                },
            };
        }

        pub fn controlAllocator(self: *const Self) Allocator {
            return self.lifecycle_header.control_allocator;
        }

        pub fn rootBackingAllocator(self: *const Self) Allocator {
            return self.root_backing;
        }

        pub fn parentRef(self: *Self) ParentRef {
            return .{
                .lifecycle = &self.lifecycle_header,
                .runtime_export = if (comptime Def.capabilities.runtime_export) &self.runtime_export else null,
            };
        }

        pub fn currentBytes(self: *const Self) usize {
            return self.state.currentBytes();
        }

        pub fn peakBytes(self: *const Self) usize {
            return self.state.peakBytes();
        }

        pub fn allocationCount(self: *const Self) usize {
            return self.state.allocationCount();
        }

        pub fn deallocationCount(self: *const Self) usize {
            return self.state.deallocationCount();
        }

        pub fn budgetPercent(self: *const Self) f32 {
            return self.state.budgetPercent();
        }

        pub fn hardcapPercent(self: *const Self) f32 {
            return self.state.hardcapPercent();
        }

        pub fn markFrame(self: *Self) void {
            self.state.markFrame();
        }

        pub fn frameDelta(self: *const Self) i64 {
            return self.state.frameDelta();
        }

        pub fn frameAllocs(self: *const Self) usize {
            return self.state.frameAllocs();
        }

        pub fn frameFrees(self: *const Self) usize {
            return self.state.frameFrees();
        }

        /// Tear down the core. Returns `.live_children` (non-destructive) while
        /// any child is still attached; otherwise unlinks from the runtime and
        /// parent, frees the core on its control allocator, and returns `.leak`
        /// when live bytes remained or `.ok` when clean.
        pub fn deinit(self: *Self) Runtime.DeinitStatus {
            if (lifecycle.hasLiveChildren(&self.lifecycle_header)) return .live_children;

            const leaked = self.currentBytes() != 0;
            if (comptime Def.capabilities.runtime_export) {
                Runtime.unlink(&self.runtime_export);
            }
            lifecycle.detachFromParent(&self.lifecycle_header);

            const control_allocator = self.lifecycle_header.control_allocator;
            control_allocator.destroy(self);

            return if (leaked) .leak else .ok;
        }

        // Build a ZoneInfo snapshot for the runtime registry. Each counter is
        // read independently, so a row can be internally skewed under live
        // mutation -- a reporting readout, not a transactional point-in-time view.
        fn query(ctx: *const anyopaque) ZoneInfo {
            const self: *const Self = @ptrCast(@alignCast(ctx));
            return .{
                .id = @intFromPtr(&self.runtime_export),
                .parent_id = if (self.runtime_export.parent) |parent| (if (parent.runtime_linked) @intFromPtr(parent) else null) else null,
                .name = Def.zone_name,
                .local_name = Def.zone_local_name,
                .parent_name = Def.parent_name,
                .depth = Def.depth,
                .current_bytes = self.currentBytes(),
                .peak_bytes = self.peakBytes(),
                .allocation_count = self.allocationCount(),
                .deallocation_count = self.deallocationCount(),
                .budget = Def.config.budget,
                .budget_percent = self.budgetPercent(),
                .hardcap = Def.config.hardcap,
                .hardcap_percent = self.hardcapPercent(),
                .frame_delta = self.frameDelta(),
                .frame_allocs = self.frameAllocs(),
                .frame_frees = self.frameFrees(),
            };
        }

        fn allocFn(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.state.rawAlloc(self.backing_allocator, len, alignment, ret_addr);
        }

        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.state.rawResize(self.backing_allocator, memory, alignment, new_len, ret_addr);
        }

        fn remapFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.state.rawRemap(self.backing_allocator, memory, alignment, new_len, ret_addr);
        }

        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.state.rawFree(self.backing_allocator, memory, alignment, ret_addr);
        }
    };
}
