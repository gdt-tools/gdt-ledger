//! `ZonedPool`: meter a fixed-size object pool by its retained backing storage,
//! not by per-item liveness.
//!
//! The pool hands out and recycles `Item`-sized slots from an arena, keeping
//! freed slots on a free list for reuse, so a `destroy` returns a slot to the
//! pool rather than to the allocator. The zone therefore meters the arena pages
//! the pool retains -- the number that reflects its real footprint. The zone
//! handle, arena state, and free list share one heap `Impl`; the stat accessors
//! delegate to the embedded zone.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Runtime = @import("../runtime/root.zig");

/// Pool of `Item` in the zone defined by `ZoneDef`, with natural `Item`
/// alignment. The common entry point; the other two generators add alignment
/// and `std.heap.MemoryPoolOptions` control.
pub fn ZonedPool(comptime Item: type, comptime ZoneDef: type) type {
    return ZonedPoolAligned(Item, .of(Item), ZoneDef);
}

/// `ZonedPool` with an explicit slot `alignment`.
pub fn ZonedPoolAligned(comptime Item: type, comptime alignment: Alignment, comptime ZoneDef: type) type {
    if (@alignOf(Item) == comptime alignment.toByteUnits()) {
        return ZonedPoolExtra(Item, ZoneDef, .{});
    } else {
        return ZonedPoolExtra(Item, ZoneDef, .{ .alignment = alignment });
    }
}

/// `ZonedPool` with full `std.heap.MemoryPoolOptions` (alignment, growable). The
/// generator the other two funnel into.
pub fn ZonedPoolExtra(comptime Item: type, comptime ZoneDef: type, comptime pool_options: std.heap.MemoryPoolOptions) type {
    return struct {
        const Self = @This();

        const node_alignment: Alignment = .of(*anyopaque);
        /// Bytes per pooled slot: the larger of an `Item` and a free-list node.
        pub const item_size = @max(@sizeOf(Node), @sizeOf(Item));
        /// Slot alignment: the stricter of the item's and a node pointer's.
        pub const item_alignment: Alignment = node_alignment.max(pool_options.alignment orelse .of(Item));

        const Node = struct {
            next: ?*align(item_alignment.toByteUnits()) @This(),
        };
        const NodePtr = *align(item_alignment.toByteUnits()) Node;
        const ItemPtr = *align(item_alignment.toByteUnits()) Item;

        impl: ?*Impl,

        pub const Error = error{OutOfMemory};
        pub const ResetMode = std.heap.ArenaAllocator.ResetMode;
        pub const InitOptions = struct {
            backing_allocator: Allocator,
            control_allocator: Allocator,
        };

        pub const Impl = struct {
            zone: ZoneDef,
            arena_state: std.heap.ArenaAllocator.State = .{},
            free_list: ?NodePtr = null,
        };

        /// Create a root zoned pool. `backing_allocator` feeds the pool's arena;
        /// `control_allocator` holds the wrapper and zone bookkeeping. A subzone
        /// type rejects `init` at comptime -- use `initUnder`.
        ///
        /// # Errors
        /// `error.OutOfMemory` if the control allocator cannot allocate the impl.
        pub fn init(options: InitOptions) !Self {
            if (comptime ZoneDef.is_subzone) {
                @compileError("gdt-ledger: subzone-backed pools use initUnder(.{ .parent = ... })");
            }

            const impl = try options.control_allocator.create(Impl);
            errdefer options.control_allocator.destroy(impl);

            impl.zone = try ZoneDef.init(.{
                .backing_allocator = options.backing_allocator,
                .control_allocator = options.control_allocator,
            });
            errdefer _ = impl.zone.deinit();
            impl.arena_state = .{};
            impl.free_list = null;

            return .{ .impl = impl };
        }

        /// Create this subzone-backed pool under a live `parent` zone of the
        /// matching type. Shares the parent's control allocator and links into
        /// its lifecycle. A root pool type rejects this at comptime.
        ///
        /// # Errors
        /// `error.OutOfMemory` if the control allocator cannot allocate the impl.
        pub fn initUnder(options: anytype) !Self {
            if (comptime !ZoneDef.is_subzone) {
                @compileError("gdt-ledger: root zoned pools use init(.{ .backing_allocator = ..., .control_allocator = ... })");
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
            impl.free_list = null;

            return .{ .impl = impl };
        }

        /// `init`, then preallocate `initial_size` slots so the first `create`s
        /// hit the free list instead of the allocator. # Errors: `OutOfMemory`.
        pub fn initPreheated(options: InitOptions, initial_size: usize) Error!Self {
            var pool = init(options) catch return error.OutOfMemory;
            errdefer _ = pool.deinit();
            try pool.preheat(initial_size);
            return pool;
        }

        /// `initUnder`, then preallocate `initial_size` slots. # Errors:
        /// `OutOfMemory`.
        pub fn initUnderPreheated(options: anytype, initial_size: usize) Error!Self {
            var pool = initUnder(options) catch return error.OutOfMemory;
            errdefer _ = pool.deinit();
            try pool.preheat(initial_size);
            return pool;
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

        /// Bytes the pool's arena currently has reserved from the backing
        /// allocator (retained slots, in use or on the free list).
        pub fn queryCapacity(self: *Self) usize {
            const impl = self.implOrPanic();
            var arena = impl.arena_state.promote(impl.zone.allocator());
            return arena.queryCapacity();
        }

        /// Preallocate `size` slots onto the free list. # Errors: `OutOfMemory`
        /// if the backing allocator cannot grow the arena.
        pub fn preheat(self: *Self, size: usize) Error!void {
            const impl = self.implOrPanic();
            var i: usize = 0;
            while (i < size) : (i += 1) {
                const raw_mem = try self.allocNew();
                const free_node = @as(NodePtr, @ptrCast(raw_mem));
                free_node.* = Node{ .next = impl.free_list };
                impl.free_list = free_node;
            }
        }

        /// Take a slot: reuse one from the free list, else grow the arena when
        /// the pool is growable. The returned item is uninitialized.
        ///
        /// # Errors
        /// `error.OutOfMemory` when the pool is not growable and the free list is
        /// empty, or the backing allocator fails.
        pub fn create(self: *Self) Error!ItemPtr {
            const impl = self.implOrPanic();
            const node = if (impl.free_list) |item| blk: {
                impl.free_list = item.next;
                break :blk item;
            } else if (pool_options.growable)
                @as(NodePtr, @ptrCast(try self.allocNew()))
            else
                return error.OutOfMemory;

            const ptr = @as(ItemPtr, @ptrCast(node));
            ptr.* = undefined;

            return ptr;
        }

        /// Return a slot to the free list for reuse. The memory is not released
        /// to the allocator -- it stays part of the pool's retained footprint.
        pub fn destroy(self: *Self, ptr: ItemPtr) void {
            const impl = self.implOrPanic();
            ptr.* = undefined;

            const node = @as(NodePtr, @ptrCast(ptr));
            node.* = Node{ .next = impl.free_list };
            impl.free_list = node;
        }

        /// Free or retain the pool's arena per `mode` and clear the free list,
        /// returning whether the reset succeeded. After this, every previously
        /// handed-out item pointer is invalid.
        pub fn reset(self: *Self, mode: ResetMode) bool {
            const impl = self.implOrPanic();
            var arena = impl.arena_state.promote(impl.zone.allocator());
            defer impl.arena_state = arena.state;

            const ok = arena.reset(mode);
            impl.free_list = null;

            return ok;
        }

        /// Tear the pool down: empty the arena, then deinit the zone. Returns
        /// `.live_children` (non-destructive, retryable) while a subzone is still
        /// alive; otherwise frees the impl and returns the zone's `.ok`/`.leak`.
        pub fn deinit(self: *Self) Runtime.DeinitStatus {
            const impl = self.impl orelse @panic("gdt-ledger: double deinit");

            // NOTE(lifecycle): .live_children must be non-destructive and
            // retryable, mirroring Zone.deinit -- empty the pool arena
            // (valid state) and keep impl alive so a retry can succeed.
            var arena = impl.arena_state.promote(impl.zone.allocator());
            _ = arena.reset(.free_all);
            impl.arena_state = arena.state;
            impl.free_list = null;

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

        fn allocNew(self: *Self) Error!*align(item_alignment.toByteUnits()) [item_size]u8 {
            const impl = self.implOrPanic();
            var arena = impl.arena_state.promote(impl.zone.allocator());
            defer impl.arena_state = arena.state;
            const mem = try arena.allocator().alignedAlloc(u8, item_alignment, item_size);

            return mem[0..item_size];
        }
    };
}

test "zoned pool create destroy reset" {
    const Zone = @import("../zone/root.zig").Zone(.{ .name = "pool" });
    if (!Zone.capabilities.stats) return error.SkipZigTest;

    const Pool = ZonedPool(u32, Zone);
    var pool = try Pool.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });

    const p1 = try pool.create();
    const p2 = try pool.create();
    p1.* = 1;
    p2.* = 2;
    try std.testing.expect(pool.currentBytes() >= 2 * @sizeOf(u32));

    pool.destroy(p1);
    const p3 = try pool.create();
    try std.testing.expect(p3 == p1);

    try std.testing.expect(pool.reset(.free_all));
    try std.testing.expectEqual(@as(usize, 0), pool.currentBytes());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, pool.deinit());
}

test "pool deinit with live child zone is non-destructive and retryable" {
    const Zone = @import("../zone/root.zig").Zone(.{ .name = "pool_live" });
    const Child = Zone.subzone(.{ .name = "child" });
    if (!Zone.capabilities.lifecycle) return error.SkipZigTest;

    const Pool = ZonedPool(u64, Zone);
    var pool = try Pool.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    var child = try Child.initUnder(.{ .parent = &pool.impl.?.zone });

    try std.testing.expectEqual(Runtime.DeinitStatus.live_children, pool.deinit());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, child.deinit());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, pool.deinit());
}

test "subzone pool counts into parent" {
    const Physics = @import("../zone/root.zig").Zone(.{ .name = "physics" });
    const Bullets = Physics.subzone(.{ .name = "bullets" });
    if (!Bullets.capabilities.stats) return error.SkipZigTest;

    const Pool = ZonedPool(u16, Bullets);

    var physics = try Physics.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    var pool = try Pool.initUnderPreheated(.{ .parent = &physics }, 4);
    try std.testing.expect(pool.currentBytes() > 0);
    try std.testing.expect(physics.currentBytes() >= pool.currentBytes());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, pool.deinit());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, physics.deinit());
}
