//! `ZonedArena`: meter a `std.heap.ArenaAllocator` by its retained backing
//! pages, not by per-object allocations.
//!
//! An arena's `free` is mostly a no-op and `reset`/`deinit` bulk-free its pages,
//! so a plain zone wrapped around one would misreport retained memory. This
//! wrapper sits the zone *below* the arena: the zone meters the chunk traffic
//! the arena pulls from the backing allocator, which is the number that reflects
//! the arena's real footprint. The zone handle and the arena state share one
//! heap `Impl`, so the public handle can move after init.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Runtime = @import("../runtime/root.zig");

/// Wrap an arena allocator in the zone defined by `ZoneDef`. The stat accessors
/// (`currentBytes`, `peakBytes`, ...) delegate to the embedded zone and report
/// retained arena pages, not logical object liveness.
pub fn ZonedArena(comptime ZoneDef: type) type {
    return struct {
        impl: ?*Impl,

        const Self = @This();

        pub const InitOptions = struct {
            backing_allocator: Allocator,
            control_allocator: Allocator,
        };

        pub const Impl = struct {
            zone: ZoneDef,
            arena_state: std.heap.ArenaAllocator.State = .{},
        };

        /// Create a root zoned arena. `backing_allocator` feeds the arena's
        /// pages; `control_allocator` holds the wrapper and zone bookkeeping. A
        /// subzone-backed arena rejects `init` at comptime -- use `initUnder`.
        ///
        /// # Errors
        /// `error.OutOfMemory` if the control allocator cannot allocate the impl
        /// (or the zone it contains).
        pub fn init(options: InitOptions) !Self {
            if (comptime ZoneDef.is_subzone) {
                @compileError("gdt-ledger: subzone-backed arenas use initUnder(.{ .parent = ... })");
            }

            const impl = try options.control_allocator.create(Impl);
            errdefer options.control_allocator.destroy(impl);

            impl.zone = try ZoneDef.init(.{
                .backing_allocator = options.backing_allocator,
                .control_allocator = options.control_allocator,
            });
            errdefer _ = impl.zone.deinit();
            impl.arena_state = .{};

            return .{ .impl = impl };
        }

        /// Create this subzone-backed arena under a live `parent` zone of the
        /// matching type. Shares the parent's control allocator and links into
        /// its lifecycle. A root arena type rejects this at comptime.
        ///
        /// # Errors
        /// `error.OutOfMemory` if the control allocator cannot allocate the impl.
        pub fn initUnder(options: anytype) !Self {
            if (comptime !ZoneDef.is_subzone) {
                @compileError("gdt-ledger: root zoned arenas use init(.{ .backing_allocator = ..., .control_allocator = ... })");
            }
            if (@TypeOf(options.parent) != *ZoneDef.ParentZone) {
                @compileError("gdt-ledger: initUnder expects parent *" ++ @typeName(ZoneDef.ParentZone));
            }

            const control_allocator = options.parent.controlAllocator();
            const impl = try control_allocator.create(Impl);
            errdefer control_allocator.destroy(impl);

            impl.zone = try ZoneDef.initUnder(.{ .parent = options.parent });
            errdefer _ = impl.zone.deinit();
            impl.arena_state = .{};

            return .{ .impl = impl };
        }

        /// The arena's `std.mem.Allocator`. Allocations are served by the arena;
        /// the zone below it meters the pages the arena pulls from the backing
        /// allocator.
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

        /// Bytes the arena currently has reserved from the backing allocator,
        /// counting both space handed out and space held for reuse.
        pub fn queryCapacity(self: *Self) usize {
            const impl = self.implOrPanic();
            var arena = impl.arena_state.promote(impl.zone.allocator());
            return arena.queryCapacity();
        }

        /// Reset the arena per `mode` (`.free_all`, `.retain_capacity`, ...) and
        /// report success. Frees or retains the backing pages, and the zone's
        /// metered footprint follows.
        pub fn reset(self: *Self, mode: std.heap.ArenaAllocator.ResetMode) bool {
            const impl = self.implOrPanic();
            var arena = impl.arena_state.promote(impl.zone.allocator());
            defer impl.arena_state = arena.state;

            return arena.reset(mode);
        }

        /// Tear the wrapper down: empty the arena, then deinit the zone. Returns
        /// `.live_children` (non-destructive, retryable) while a subzone is still
        /// alive; otherwise frees the impl and returns the zone's `.ok`/`.leak`.
        pub fn deinit(self: *Self) Runtime.DeinitStatus {
            const impl = self.impl orelse @panic("gdt-ledger: double deinit");

            // NOTE(lifecycle): .live_children must be non-destructive and
            // retryable, mirroring Zone.deinit -- the wrapper used to tear
            // the arena down and destroy impl anyway, permanently orphaning
            // the still-linked ZoneCore and pinning every ancestor's
            // live_children. The arena is emptied (reset, valid state)
            // rather than deinit'ed so a retry after the children die works.
            var arena = impl.arena_state.promote(impl.zone.allocator());
            _ = arena.reset(.free_all);
            impl.arena_state = arena.state;

            const control_allocator = impl.zone.controlAllocator();
            const status = impl.zone.deinit();
            if (status == .live_children) return status;

            control_allocator.destroy(impl);
            self.impl = null;

            return status;
        }

        fn implOrPanic(self: *const Self) *Impl {
            return self.impl orelse @panic("gdt-ledger: use after deinit");
        }

        fn allocFn(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const impl: *Impl = @ptrCast(@alignCast(ctx));
            var arena = impl.arena_state.promote(impl.zone.allocator());
            defer impl.arena_state = arena.state;

            return arena.allocator().rawAlloc(len, alignment, ret_addr);
        }

        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            const impl: *Impl = @ptrCast(@alignCast(ctx));
            var arena = impl.arena_state.promote(impl.zone.allocator());
            defer impl.arena_state = arena.state;

            return arena.allocator().rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remapFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const impl: *Impl = @ptrCast(@alignCast(ctx));
            var arena = impl.arena_state.promote(impl.zone.allocator());
            defer impl.arena_state = arena.state;

            return arena.allocator().rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const impl: *Impl = @ptrCast(@alignCast(ctx));
            var arena = impl.arena_state.promote(impl.zone.allocator());
            defer impl.arena_state = arena.state;

            arena.allocator().rawFree(memory, alignment, ret_addr);
        }
    };
}

test "zoned arena tracks retained arena footprint and reset" {
    const Zone = @import("../zone/root.zig").Zone(.{ .name = "arena" });
    if (!Zone.capabilities.stats) return error.SkipZigTest;

    const Arena = ZonedArena(Zone);
    var arena = try Arena.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    const ally = arena.allocator();

    const a = try ally.alloc(u8, 64);
    try std.testing.expect(arena.currentBytes() >= 64);
    try std.testing.expect(arena.queryCapacity() >= 64);

    ally.free(a);
    try std.testing.expect(arena.currentBytes() >= 64);

    try std.testing.expect(arena.reset(.free_all));
    try std.testing.expectEqual(@as(usize, 0), arena.currentBytes());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, arena.deinit());
}

test "arena deinit with live child zone is non-destructive and retryable" {
    const Zone = @import("../zone/root.zig").Zone(.{ .name = "arena_live" });
    const Child = Zone.subzone(.{ .name = "child" });
    if (!Zone.capabilities.lifecycle) return error.SkipZigTest;

    const Arena = ZonedArena(Zone);
    var arena = try Arena.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    var child = try Child.initUnder(.{ .parent = &arena.impl.?.zone });

    try std.testing.expectEqual(Runtime.DeinitStatus.live_children, arena.deinit());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, child.deinit());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, arena.deinit());
}

test "subzone arena counts into parent" {
    const Physics = @import("../zone/root.zig").Zone(.{ .name = "physics" });
    const Scratch = Physics.subzone(.{ .name = "scratch" });
    if (!Scratch.capabilities.stats) return error.SkipZigTest;

    const Arena = ZonedArena(Scratch);

    var physics = try Physics.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    var arena = try Arena.initUnder(.{ .parent = &physics });
    const ally = arena.allocator();

    _ = try ally.alloc(u8, 32);
    try std.testing.expect(arena.currentBytes() >= 32);
    try std.testing.expect(physics.currentBytes() >= 32);

    try std.testing.expect(arena.reset(.free_all));
    try std.testing.expectEqual(@as(usize, 0), physics.currentBytes());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, arena.deinit());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, physics.deinit());
}
