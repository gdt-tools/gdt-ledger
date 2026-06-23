//! `ZonedDebug`: stack a ledger zone on top of `std.heap.DebugAllocator` so one
//! `deinit` returns both verdicts.
//!
//! The zone says WHICH subsystem is involved (its name and live bytes); the
//! embedded `DebugAllocator` says WHICH allocation leaked and writes that
//! allocation's stack trace itself. The zone meters the debug allocator's
//! output. This wrapper never captures per-allocation traces -- that is the
//! `DebugAllocator`'s job; it only bundles the pairing into one handle and one
//! `deinit`.

const std = @import("std");

const Allocator = std.mem.Allocator;

const Runtime = @import("../runtime/root.zig");

/// Wrap the zone defined by `ZoneDef` around a `std.heap.DebugAllocator`
/// configured by `debug_config`. The stat accessors delegate to the zone; the
/// debug allocator's own leak check is reported separately by `deinit`.
pub fn ZonedDebug(
    comptime ZoneDef: type,
    comptime debug_config: std.heap.DebugAllocatorConfig,
) type {
    const Debug = std.heap.DebugAllocator(debug_config);

    return struct {
        impl: ?*Impl,

        const Self = @This();

        pub const InitOptions = struct {
            backing_allocator: Allocator,
            control_allocator: Allocator,
        };

        /// Both verdicts from one `deinit`: the zone's status and the embedded
        /// debug allocator's leak check. `debug` is only meaningful when `zone`
        /// is not `.live_children` -- a live-children deinit is non-destructive
        /// and retryable, so the debug allocator has not been checked yet and
        /// `debug` is reported `.ok` as a placeholder.
        pub const DeinitStatus = struct {
            zone: Runtime.DeinitStatus,
            debug: std.heap.Check,
        };

        pub const Impl = struct {
            debug: Debug,
            zone: ZoneDef,
        };

        /// Create a root zoned debug allocator. The debug allocator draws from
        /// `backing_allocator` and the zone meters allocations through it;
        /// `control_allocator` holds the wrapper and zone bookkeeping. A subzone
        /// type rejects `init` at comptime -- use `initUnder`.
        ///
        /// # Errors
        /// `error.OutOfMemory` if the control allocator cannot allocate the impl.
        pub fn init(options: InitOptions) !Self {
            if (comptime ZoneDef.is_subzone) {
                @compileError("gdt-ledger: subzone-backed debug allocators use initUnder(.{ .parent = ... })");
            }

            const impl = try options.control_allocator.create(Impl);
            errdefer options.control_allocator.destroy(impl);

            impl.debug = .{ .backing_allocator = options.backing_allocator };
            impl.zone = try ZoneDef.init(.{
                .backing_allocator = impl.debug.allocator(),
                .control_allocator = options.control_allocator,
            });
            errdefer _ = impl.zone.deinit();

            return .{ .impl = impl };
        }

        /// Create this subzone-backed debug allocator under a live `parent`. The
        /// debug allocator draws from the parent's allocator and the zone counts
        /// into the parent. A root type rejects this at comptime.
        ///
        /// # Errors
        /// `error.OutOfMemory` if the control allocator cannot allocate the impl.
        pub fn initUnder(options: anytype) !Self {
            if (comptime !ZoneDef.is_subzone) {
                @compileError("gdt-ledger: root zoned debug allocators use init(.{ .backing_allocator = ..., .control_allocator = ... })");
            }
            if (@TypeOf(options.parent) != *ZoneDef.ParentZone) {
                @compileError("gdt-ledger: initUnder expects parent *" ++ @typeName(ZoneDef.ParentZone));
            }

            const control_allocator = options.parent.controlAllocator();
            const impl = try control_allocator.create(Impl);
            errdefer control_allocator.destroy(impl);

            impl.debug = .{ .backing_allocator = options.parent.allocator() };
            impl.zone = try ZoneDef.initUnderWithBacking(.{
                .parent = options.parent,
                .backing_allocator = impl.debug.allocator(),
            });
            errdefer _ = impl.zone.deinit();

            return .{ .impl = impl };
        }

        /// The allocator to hand out: the zone's allocator wrapping the debug
        /// allocator, so allocations are leak-checked and metered.
        pub fn allocator(self: *Self) Allocator {
            return self.implOrPanic().zone.allocator();
        }

        pub fn currentBytes(self: *const Self) usize {
            return self.implOrPanic().zone.currentBytes();
        }
        pub fn peakBytes(self: *const Self) usize {
            return self.implOrPanic().zone.peakBytes();
        }
        pub fn allocationCount(self: *const Self) usize {
            return self.implOrPanic().zone.allocationCount();
        }
        pub fn deallocationCount(self: *const Self) usize {
            return self.implOrPanic().zone.deallocationCount();
        }
        pub fn budgetPercent(self: *const Self) f32 {
            return self.implOrPanic().zone.budgetPercent();
        }
        pub fn hardcapPercent(self: *const Self) f32 {
            return self.implOrPanic().zone.hardcapPercent();
        }
        pub fn zoneName(self: *const Self) []const u8 {
            return self.implOrPanic().zone.zoneName();
        }
        pub fn markFrame(self: *Self) void {
            self.implOrPanic().zone.markFrame();
        }
        pub fn frameDelta(self: *const Self) i64 {
            return self.implOrPanic().zone.frameDelta();
        }
        pub fn frameAllocs(self: *const Self) usize {
            return self.implOrPanic().zone.frameAllocs();
        }
        pub fn frameFrees(self: *const Self) usize {
            return self.implOrPanic().zone.frameFrees();
        }

        /// Tear down the wrapper and return both verdicts. Deinits the zone
        /// first; on `.live_children` it stops there non-destructively (the debug
        /// allocator still backs the live children) and reports `debug = .ok`.
        /// Otherwise it runs the debug allocator's leak check -- which writes any
        /// leaking allocation's stack trace -- frees the impl, and returns both.
        pub fn deinit(self: *Self) DeinitStatus {
            const impl = self.impl orelse @panic("gdt-ledger: double deinit");
            const control_allocator = impl.zone.controlAllocator();
            const zone_status = impl.zone.deinit();

            // NOTE(lifecycle): on .live_children the zone impl survives with
            // backing_allocator pointing INTO impl.debug -- tearing the debug
            // allocator down and destroying impl here was a use-after-free
            // through every still-live zone in the subtree (reproduced
            // segfault/deadlock). Keep everything alive and retryable.
            if (zone_status == .live_children) {
                return .{ .zone = zone_status, .debug = .ok };
            }

            const debug_status = impl.debug.deinit();

            control_allocator.destroy(impl);
            self.impl = null;

            return .{
                .zone = zone_status,
                .debug = debug_status,
            };
        }

        fn implOrPanic(self: *const Self) *Impl {
            return self.impl orelse @panic("gdt-ledger: use after deinit");
        }
    };
}

test "zoned debug returns both zone and debug status" {
    const Zone = @import("../zone/root.zig").Zone(.{ .name = "debug" });
    const Wrapped = ZonedDebug(Zone, .{});
    var wrapped = try Wrapped.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    const ally = wrapped.allocator();

    const slice = try ally.alloc(u8, 64);
    ally.free(slice);

    const status = wrapped.deinit();
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, status.zone);
    try std.testing.expectEqual(std.heap.Check.ok, status.debug);
}

test "debug deinit with live child zone is non-destructive and retryable" {
    const Zone = @import("../zone/root.zig").Zone(.{ .name = "debug_live" });
    const Child = Zone.subzone(.{ .name = "child" });
    if (!Zone.capabilities.lifecycle) return error.SkipZigTest;

    const Wrapped = ZonedDebug(Zone, .{});
    var wrapped = try Wrapped.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    var child = try Child.initUnder(.{ .parent = &wrapped.impl.?.zone });

    const first = wrapped.deinit();
    try std.testing.expectEqual(Runtime.DeinitStatus.live_children, first.zone);

    // The kept-alive debug allocator must still back the live child -- this
    // exact path used to dereference the destroyed wrapper impl.
    const ally = child.allocator();
    const slice = try ally.alloc(u8, 16);
    ally.free(slice);

    try std.testing.expectEqual(Runtime.DeinitStatus.ok, child.deinit());
    const second = wrapped.deinit();
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, second.zone);
    try std.testing.expectEqual(std.heap.Check.ok, second.debug);
}

test "subzone debug counts into parent" {
    const Physics = @import("../zone/root.zig").Zone(.{ .name = "physics" });
    const Scratch = Physics.subzone(.{ .name = "debug" });
    if (!Scratch.capabilities.stats) return error.SkipZigTest;

    const Wrapped = ZonedDebug(Scratch, .{});

    var physics = try Physics.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    var wrapped = try Wrapped.initUnder(.{ .parent = &physics });
    const ally = wrapped.allocator();

    const slice = try ally.alloc(u8, 32);
    try std.testing.expectEqual(@as(usize, 32), wrapped.currentBytes());
    try std.testing.expect(physics.currentBytes() >= wrapped.currentBytes());

    ally.free(slice);
    try std.testing.expectEqual(@as(usize, 0), wrapped.currentBytes());
    const status = wrapped.deinit();

    try std.testing.expectEqual(Runtime.DeinitStatus.ok, status.zone);
    try std.testing.expectEqual(std.heap.Check.ok, status.debug);
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, physics.deinit());
}
