//! Zone factory: turns a `ZoneConfig` into a concrete zone type, and the facade
//! for the zone family.
//!
//! `Zone(config)` and `scope("...").Zone(config)` are the public entry points.
//! The per-config type they return wraps a backing allocator and exposes the
//! accounting API (live bytes, peak, budgets, hardcaps, frame deltas, deinit
//! status) plus subzone creation. The metering itself lives in `enabled.zig`
//! (`ZoneCore`); this file owns config resolution, the public method surface,
//! and the lifecycle rules.
//!
//! Two shapes come out of the same factory. When the effective mode is `.off`,
//! the returned type is a zero-state passthrough whose `allocator()` is the bare
//! backing allocator and whose accounting methods are no-ops; otherwise it holds
//! a heap `Impl` and delegates to `ZoneCore`. Both shapes expose an identical
//! public API and a comptime `effective_mode` decl, so calling code is the same
//! either way.

const std = @import("std");

const Allocator = std.mem.Allocator;

const policy = @import("../policy.zig");
const capabilities_mod = @import("../capabilities.zig");
const Runtime = @import("../runtime/root.zig");
const ZoneConfig = @import("../config/zone.zig");
const validation = @import("../validation.zig");
const SubzoneConfig = @import("../config/subzone.zig");
const zone_core = @import("enabled.zig");
const ParentRef = zone_core.ParentRef;
const ZoneCore = zone_core.ZoneCore;

/// Build a zone type from a fully-resolved config and parentage.
///
/// Resolves the effective mode (rule resolution, then a subzone clamp against
/// `parent_effective_mode`) and the capability set, then returns the `.off`
/// passthrough shape or the metered shape. Private: callers reach it through
/// `Zone`, `scope`, or `subzone`. `@compileError`s on an invalid name and on
/// `tracy = true`, which is not implemented.
fn ZoneDefinition(
    comptime base_config: ZoneConfig,
    comptime local_name: []const u8,
    comptime parent_zone_name: ?[]const u8,
    comptime ParentZoneType: type,
    comptime zone_depth: usize,
    comptime is_scoped_def: bool,
    comptime parent_effective_mode: ?policy.LedgerMode,
) type {
    validation.validateName(base_config.name, "zone name");
    validation.validateName(local_name, "zone local name");

    if (base_config.tracy) {
        @compileError("gdt-ledger: .tracy = true is not implemented yet");
    }

    const is_subzone_def = parent_zone_name != null;
    const zone_config_value = base_config;
    const zone_resolved_mode = policy.resolveMode(zone_config_value.name, is_scoped_def);
    const zone_effective_mode = if (parent_effective_mode) |parent_mode|
        policy.clampMode(parent_mode, zone_resolved_mode)
    else
        zone_resolved_mode;
    const zone_capabilities = capabilities_mod.resolve(zone_effective_mode, zone_config_value);
    const CoreDef = struct {
        pub const config = zone_config_value;
        pub const capabilities = zone_capabilities;
        pub const zone_name = zone_config_value.name;
        pub const zone_local_name = local_name;
        pub const parent_name = parent_zone_name;
        pub const depth = zone_depth;
    };

    if (zone_effective_mode == .off) {
        // Off-mode shape: zero state, no books. `allocator()` hands back the
        // backing allocator unchanged, every accounting method is a no-op
        // returning 0, and `deinit()` always reports `.ok`. Selected when the
        // effective mode is `.off`, including a subzone clamped to `.off` by its
        // parent. The public API matches the metered shape below so call sites
        // do not branch on mode.
        return struct {
            backing_allocator: Allocator,
            control_allocator: Allocator,

            const Self = @This();

            pub const config = zone_config_value;
            pub const effective_mode = zone_effective_mode;
            pub const capabilities = zone_capabilities;
            pub const ParentZone = ParentZoneType;
            pub const is_subzone = is_subzone_def;
            pub const is_scoped = is_scoped_def;
            pub const zone_name = zone_config_value.name;
            pub const zone_local_name = local_name;
            pub const parent_name = parent_zone_name;
            pub const depth = zone_depth;
            pub const root_name = if (is_subzone_def) ParentZone.root_name else zone_name;
            pub const tracy_zone_name = validation.sentinelName(zone_name);
            pub const InitOptions = struct {
                backing_allocator: Allocator,
                control_allocator: Allocator,
            };
            pub const State = struct {};
            pub const Impl = void;

            pub fn subzone(comptime child: SubzoneConfig) type {
                return makeSubzone(Self, child);
            }

            pub fn init(options: InitOptions) !Self {
                if (is_subzone_def) {
                    @compileError("gdt-ledger: subzones use initUnder(.{ .parent = ... })");
                }

                return .{
                    .backing_allocator = options.backing_allocator,
                    .control_allocator = options.control_allocator,
                };
            }

            pub fn initUnder(options: anytype) !Self {
                if (!is_subzone_def) {
                    @compileError("gdt-ledger: root zones use init(.{ .backing_allocator = ..., .control_allocator = ... })");
                }
                if (@TypeOf(options.parent) != *ParentZoneType) {
                    @compileError("gdt-ledger: initUnder expects parent *" ++ @typeName(ParentZoneType));
                }

                // NOTE(off-mode): an off subzone must NOT capture
                // parent.allocator() -- for an enabled parent that is a vtable
                // whose ctx is the parent's heap impl, and off zones don't
                // lifecycle-attach, so the parent deinits .ok and the next
                // alloc through this child dereferenced freed memory
                // (reproduced segfault). Capturing the ROOT backing
                // (app-owned, value copy) makes that structurally impossible;
                // the chosen consequence is that an off subtree allocates
                // straight from the root allocator, invisible to every
                // ancestor's stats and hardcaps -- "off" means off the books.
                return .{
                    .backing_allocator = options.parent.rootBackingAllocator(),
                    .control_allocator = options.parent.controlAllocator(),
                };
            }

            pub fn initUnderWithBacking(options: anytype) !Self {
                if (!is_subzone_def) {
                    @compileError("gdt-ledger: root zones use init(.{ .backing_allocator = ..., .control_allocator = ... })");
                }
                if (@TypeOf(options.parent) != *ParentZoneType) {
                    @compileError("gdt-ledger: initUnderWithBacking expects parent *" ++ @typeName(ParentZoneType));
                }

                return .{
                    .backing_allocator = options.backing_allocator,
                    .control_allocator = options.parent.controlAllocator(),
                };
            }

            pub fn allocator(self: *Self) Allocator {
                return self.backing_allocator;
            }

            pub fn controlAllocator(self: *const Self) Allocator {
                return self.control_allocator;
            }

            pub fn rootBackingAllocator(self: *const Self) Allocator {
                // By induction this is always the app-owned root backing: an
                // off root stores what the app passed; an off subzone stored
                // its parent's rootBackingAllocator() at initUnder.
                return self.backing_allocator;
            }

            fn parentRef(self: *Self) ?ParentRef {
                _ = self;
                return null;
            }

            pub fn currentBytes(self: *const Self) usize {
                _ = self;
                return 0;
            }
            pub fn peakBytes(self: *const Self) usize {
                _ = self;
                return 0;
            }
            pub fn allocationCount(self: *const Self) usize {
                _ = self;
                return 0;
            }
            pub fn deallocationCount(self: *const Self) usize {
                _ = self;
                return 0;
            }
            pub fn budgetPercent(self: *const Self) f32 {
                _ = self;
                return 0;
            }
            pub fn hardcapPercent(self: *const Self) f32 {
                _ = self;
                return 0;
            }
            pub fn zoneName(self: *const Self) []const u8 {
                _ = self;
                return zone_name;
            }
            pub fn markFrame(self: *Self) void {
                _ = self;
            }
            pub fn frameDelta(self: *const Self) i64 {
                _ = self;
                return 0;
            }
            pub fn frameAllocs(self: *const Self) usize {
                _ = self;
                return 0;
            }
            pub fn frameFrees(self: *const Self) usize {
                _ = self;
                return 0;
            }

            // NOTE(safety): off-mode deinit poisons with undefined and
            // reports .ok unconditionally -- double-deinit/use-after-deinit
            // are only DETECTED (clean panics) under .full/.guardrails.
            // Deliberate zero-cost trade-off: off mode adds no
            // checks ever; dev builds run instrumented and surface lifecycle
            // bugs there. The poison keeps Debug-mode 0xaa detection useful.
            pub fn deinit(self: *Self) Runtime.DeinitStatus {
                self.* = undefined;
                return .ok;
            }
        };
    }

    // Metered shape: holds a heap-allocated `Impl` (the `ZoneCore`) and
    // delegates accounting to it. `impl` is nulled on a clean `deinit`, so the
    // post-deinit methods panic instead of touching freed state.
    return struct {
        impl: ?*Impl,

        const Self = @This();

        pub const config = zone_config_value;
        /// The mode this zone actually runs at after rule resolution and the
        /// subzone clamp. Readable at comptime for tests and for branching on
        /// whether a capability is compiled in.
        pub const effective_mode = zone_effective_mode;
        pub const capabilities = zone_capabilities;
        pub const ParentZone = ParentZoneType;
        pub const is_subzone = is_subzone_def;
        pub const is_scoped = is_scoped_def;
        pub const zone_name = zone_config_value.name;
        pub const zone_local_name = local_name;
        pub const parent_name = parent_zone_name;
        pub const depth = zone_depth;
        pub const root_name = if (is_subzone_def) ParentZone.root_name else zone_name;
        pub const tracy_zone_name = validation.sentinelName(zone_name);
        pub const InitOptions = struct {
            backing_allocator: Allocator,
            control_allocator: Allocator,
        };

        pub const Impl = ZoneCore(CoreDef);
        pub const State = Impl.State;

        /// Derive a child zone type nested under this one. The child's path is
        /// this zone's path joined with `child.name` by '/', unset child fields
        /// inherit this zone's config, and the child's effective mode is clamped
        /// to this zone's. Instantiate the result with `initUnder`.
        pub fn subzone(comptime child: SubzoneConfig) type {
            return makeSubzone(Self, child);
        }

        /// Create a root zone. `backing_allocator` receives user allocations;
        /// `control_allocator` holds the ledger's own bookkeeping, kept off the
        /// books it audits. A subzone type rejects `init` at comptime -- use
        /// `initUnder`.
        ///
        /// # Errors
        /// `error.OutOfMemory` if the control allocator cannot allocate the impl.
        pub fn init(options: InitOptions) !Self {
            if (is_subzone_def) {
                @compileError("gdt-ledger: subzones use initUnder(.{ .parent = ... })");
            }

            return initWithParent(options.backing_allocator, options.control_allocator, options.backing_allocator, null);
        }

        /// Create this subzone under a live `parent` of the matching type. The
        /// child inherits the parent's backing and control allocators and links
        /// into its lifecycle, so the parent's `deinit` reports `.live_children`
        /// until the child is torn down. A root zone type rejects this at
        /// comptime.
        ///
        /// # Errors
        /// `error.OutOfMemory` if the control allocator cannot allocate the impl.
        pub fn initUnder(options: anytype) !Self {
            if (!is_subzone_def) {
                @compileError("gdt-ledger: root zones use init(.{ .backing_allocator = ..., .control_allocator = ... })");
            }
            if (@TypeOf(options.parent) != *ParentZoneType) {
                @compileError("gdt-ledger: initUnder expects parent *" ++ @typeName(ParentZoneType));
            }

            return initWithParent(options.parent.allocator(), options.parent.controlAllocator(), options.parent.rootBackingAllocator(), options.parent.parentRef());
        }

        /// Like `initUnder`, but draw user bytes from an injected
        /// `backing_allocator` instead of the parent's. The control allocator
        /// and the root backing (captured by any `.off` descendant) still come
        /// from the parent chain; the injected allocator is deliberately not used
        /// as the root backing -- see the note below.
        ///
        /// # Errors
        /// `error.OutOfMemory` if the control allocator cannot allocate the impl.
        pub fn initUnderWithBacking(options: anytype) !Self {
            if (!is_subzone_def) {
                @compileError("gdt-ledger: root zones use init(.{ .backing_allocator = ..., .control_allocator = ... })");
            }
            if (@TypeOf(options.parent) != *ParentZoneType) {
                @compileError("gdt-ledger: initUnderWithBacking expects parent *" ++ @typeName(ParentZoneType));
            }

            // NOTE(ownership): root_backing is inherited from the parent chain,
            // NOT taken from the injected backing -- the injected allocator's
            // lifetime is the caller's business (ZonedDebug injects a pointer
            // into its own heap impl), and off descendants must only ever
            // capture an allocator that outlives every intermediate zone.
            return initWithParent(options.backing_allocator, options.parent.controlAllocator(), options.parent.rootBackingAllocator(), options.parent.parentRef());
        }

        fn initWithParent(backing_allocator: Allocator, control_allocator: Allocator, root_backing: Allocator, parent: ?ParentRef) !Self {
            return .{ .impl = try Impl.create(backing_allocator, control_allocator, root_backing, parent) };
        }

        /// This zone's user-facing allocator. Allocations through it are metered
        /// before reaching the backing allocator.
        pub fn allocator(self: *Self) Allocator {
            return self.implOrPanic().allocator();
        }

        /// The allocator holding this zone's bookkeeping, separate from the
        /// backing allocator it meters. Subzones share their root's.
        pub fn controlAllocator(self: *const Self) Allocator {
            return self.implOrPanic().controlAllocator();
        }

        /// The app-owned root backing allocator for this zone's tree. An `.off`
        /// subzone captures this so it never dangles on a parent's freed impl.
        pub fn rootBackingAllocator(self: *const Self) Allocator {
            return self.implOrPanic().rootBackingAllocator();
        }

        fn parentRef(self: *Self) ?ParentRef {
            return self.implOrPanic().parentRef();
        }

        /// Live tracked bytes in this zone.
        pub fn currentBytes(self: *const Self) usize {
            return self.implOrPanic().currentBytes();
        }
        /// High-water mark of live bytes since init.
        pub fn peakBytes(self: *const Self) usize {
            return self.implOrPanic().peakBytes();
        }
        /// Cumulative allocations made through this zone.
        pub fn allocationCount(self: *const Self) usize {
            return self.implOrPanic().allocationCount();
        }
        /// Cumulative frees made through this zone.
        pub fn deallocationCount(self: *const Self) usize {
            return self.implOrPanic().deallocationCount();
        }
        /// Live bytes as a percentage of the budget. May exceed 100: the budget
        /// is a gauge, not a ceiling. 0 when no budget is configured.
        pub fn budgetPercent(self: *const Self) f32 {
            return self.implOrPanic().budgetPercent();
        }
        /// Live bytes as a percentage of the hardcap. 0 when no hardcap is set.
        pub fn hardcapPercent(self: *const Self) f32 {
            return self.implOrPanic().hardcapPercent();
        }
        /// This zone's full scope path (e.g. "physics/bullets").
        pub fn zoneName(self: *const Self) []const u8 {
            _ = self;
            return zone_name;
        }
        /// Snapshot the current totals as the frame baseline; the `frame*`
        /// readers then report against it. No-op unless frame tracking is on
        /// (`.full` plus `frame_tracking`). Not coherent under concurrent calls
        /// on one zone -- treat it as an externally-synchronized frame tick.
        pub fn markFrame(self: *Self) void {
            self.implOrPanic().markFrame();
        }
        /// Net byte change since the last `markFrame`.
        pub fn frameDelta(self: *const Self) i64 {
            return self.implOrPanic().frameDelta();
        }
        /// Allocations since the last `markFrame`.
        pub fn frameAllocs(self: *const Self) usize {
            return self.implOrPanic().frameAllocs();
        }
        /// Frees since the last `markFrame`.
        pub fn frameFrees(self: *const Self) usize {
            return self.implOrPanic().frameFrees();
        }

        /// Tear the zone down. Returns `.ok` (clean), `.leak` (live bytes
        /// remained), or `.live_children` (a subzone is still alive). The
        /// `.live_children` case is non-destructive and retryable: deinit the
        /// children, then call again. Inspect `zoneName()`/`currentBytes()`
        /// before calling -- a successful deinit nulls the handle, and calling
        /// twice panics.
        pub fn deinit(self: *Self) Runtime.DeinitStatus {
            const impl = self.impl orelse @panic("gdt-ledger: double deinit");
            const status = impl.deinit();
            if (status != .live_children) self.impl = null;
            return status;
        }

        fn implOrPanic(self: *const Self) *Impl {
            return self.impl orelse @panic("gdt-ledger: use after deinit");
        }
    };
}

/// Build a child zone type under `Parent`: join the parent path with
/// `child.name`, fill unset child fields from the parent config, and thread the
/// parent's effective mode through so the child clamps to it.
fn makeSubzone(comptime Parent: type, comptime child: SubzoneConfig) type {
    validation.validatePathSegment(child.name, "subzone name");

    const child_config = ZoneConfig{
        .name = std.fmt.comptimePrint("{s}/{s}", .{ Parent.zone_name, child.name }),
        .budget = child.budget,
        .hardcap = child.hardcap,
        .frame_tracking = child.frame_tracking orelse Parent.config.frame_tracking,
        .tracy = child.tracy orelse Parent.config.tracy,
        .thread_safe = child.thread_safe orelse Parent.config.thread_safe,
    };

    return ZoneDefinition(child_config, child.name, Parent.zone_name, Parent, Parent.depth + 1, Parent.is_scoped, Parent.effective_mode);
}

/// Create a root zone type from `config`. The returned type's `init` takes the
/// backing and control allocators; `ZoneConfig` lists the knobs. Unscoped, so
/// its mode is the default mode -- use `scope(...).Zone` to make it addressable
/// by policy rules.
pub fn Zone(comptime config: ZoneConfig) type {
    return ZoneDefinition(config, config.name, null, void, 0, false, null);
}

/// Open a named policy scope. `scope("gdt_vulkan").Zone(config)` makes a root
/// zone whose path is "gdt_vulkan/<config.name>", so root rules can target it by
/// longest-prefix match. `@compileError` if the scope name is empty or contains
/// a '/'.
pub fn scope(comptime scope_name: []const u8) type {
    validation.validateScopeName(scope_name);

    return struct {
        /// Create a root zone nested under this scope. Its path is the scope name
        /// joined with `config.name`, so policy rules resolve against it.
        pub fn Zone(comptime config: ZoneConfig) type {
            validation.validatePathSegment(config.name, "scoped zone name");

            const scoped_config = ZoneConfig{
                .name = std.fmt.comptimePrint("{s}/{s}", .{ scope_name, config.name }),
                .budget = config.budget,
                .hardcap = config.hardcap,
                .frame_tracking = config.frame_tracking,
                .tracy = config.tracy,
                .thread_safe = config.thread_safe,
            };

            return ZoneDefinition(scoped_config, config.name, null, void, 0, true, null);
        }
    };
}

test "zone wraps tracked state -- stats delegate correctly" {
    const TestZone = Zone(.{ .name = "test" });
    if (!TestZone.capabilities.stats) return error.SkipZigTest;

    var zone = try TestZone.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    defer std.debug.assert(zone.deinit() == .ok);

    const ally = zone.allocator();
    const slice = try ally.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), zone.currentBytes());

    ally.free(slice);
    try std.testing.expectEqual(@as(usize, 0), zone.currentBytes());
}

test "subzone metadata composes full names and inherits defaults" {
    const Physics = Zone(.{
        .name = "physics",
        .frame_tracking = true,
        .thread_safe = false,
    });
    const Bullets = Physics.subzone(.{
        .name = "bullets",
        .budget = 1024,
    });

    try std.testing.expectEqualStrings("physics/bullets", Bullets.zone_name);
    try std.testing.expectEqualStrings("bullets", Bullets.zone_local_name);
    try std.testing.expectEqualStrings("physics", Bullets.parent_name.?);
    try std.testing.expect(Bullets.is_subzone);
    try std.testing.expectEqual(@as(usize, 1), Bullets.depth);
}

test "zone tracy name metadata is sentinel terminated" {
    const Physics = Zone(.{ .name = "physics" });
    try std.testing.expectEqual(@as(u8, 0), Physics.tracy_zone_name[Physics.tracy_zone_name.len]);
    try std.testing.expectEqualStrings("physics", Physics.tracy_zone_name[0.."physics".len]);
}

test "subzone allocations count in parent and child" {
    const Physics = Zone(.{ .name = "physics", .budget = 4096 });
    const Bullets = Physics.subzone(.{ .name = "bullets", .budget = 1024 });
    if (!Bullets.capabilities.stats) return error.SkipZigTest;

    var physics = try Physics.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    defer std.debug.assert(physics.deinit() == .ok);
    var bullets = try Bullets.initUnder(.{ .parent = &physics });
    defer std.debug.assert(bullets.deinit() == .ok);

    const ally = bullets.allocator();
    const slice = try ally.alloc(u8, 128);

    try std.testing.expectEqual(@as(usize, 128), bullets.currentBytes());
    try std.testing.expectEqual(@as(usize, 128), physics.currentBytes());

    ally.free(slice);
    try std.testing.expectEqual(@as(usize, 0), bullets.currentBytes());
    try std.testing.expectEqual(@as(usize, 0), physics.currentBytes());
}

test "parent deinit with live child is non-destructive" {
    const Parent = Zone(.{ .name = "parent" });
    const Child = Parent.subzone(.{ .name = "child" });
    if (!Parent.capabilities.lifecycle) return error.SkipZigTest;

    var parent = try Parent.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    var child = try Child.initUnder(.{ .parent = &parent });

    try std.testing.expectEqual(Runtime.DeinitStatus.live_children, parent.deinit());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, child.deinit());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, parent.deinit());
}

test "zone deinit reports leak for outstanding allocations" {
    const TestZone = Zone(.{ .name = "leaky" });
    if (!TestZone.capabilities.stats) return error.SkipZigTest;

    // page_allocator backing so the deliberate leak doesn't trip the test
    // runner's std.testing.allocator leak check; control stays testing.
    var zone = try TestZone.init(.{
        .backing_allocator = std.heap.page_allocator,
        .control_allocator = std.testing.allocator,
    });

    const ally = zone.allocator();
    const slice = try ally.alloc(u8, 64);

    try std.testing.expectEqual(Runtime.DeinitStatus.leak, zone.deinit());
    std.heap.page_allocator.free(slice);
}

test "snapshot and dumps expose live zone hierarchy" {
    const Engine = Zone(.{ .name = "engine", .budget = 4096 });
    const Render = Engine.subzone(.{ .name = "render" });
    const Audio = Zone(.{ .name = "audio" });
    if (!Engine.capabilities.runtime_export) return error.SkipZigTest;

    const runtime_mod = @import("../runtime/root.zig");
    runtime_mod.unsafeResetForTest();

    var engine = try Engine.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    var render = try Render.initUnder(.{ .parent = &engine });
    var audio = try Audio.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });

    const bytes = try render.allocator().alloc(u8, 96);

    try std.testing.expectEqual(@as(usize, 3), runtime_mod.zoneCount());

    const snap = runtime_mod.snapshot();
    try std.testing.expect(!snap.overflowed);
    try std.testing.expectEqual(@as(usize, 3), snap.len);
    // Pre-order: a child must appear after its parent, with parent_id wired.
    var engine_idx: ?usize = null;
    var render_idx: ?usize = null;
    var engine_id: usize = 0;
    for (snap.infos[0..snap.len], 0..) |info, i| {
        if (std.mem.eql(u8, info.name, "engine")) {
            engine_idx = i;
            engine_id = info.id;
        }
        if (std.mem.eql(u8, info.name, "engine/render")) render_idx = i;
    }
    try std.testing.expect(engine_idx.? < render_idx.?);
    const render_info = snap.infos[render_idx.?];
    try std.testing.expectEqual(engine_id, render_info.parent_id.?);
    try std.testing.expectEqual(@as(usize, 1), render_info.depth);
    try std.testing.expectEqual(@as(usize, 96), render_info.current_bytes);

    var text_buf: [2048]u8 = undefined;
    var text_writer: std.Io.Writer = .fixed(&text_buf);
    try runtime_mod.dumpToWriter(&text_writer);
    const text = text_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "engine") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "render") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "audio") != null);

    var json_buf: [2048]u8 = undefined;
    var json_writer: std.Io.Writer = .fixed(&json_buf);
    try runtime_mod.dumpToJson(&json_writer);
    const json = json_writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, json, "["));
    try std.testing.expect(std.mem.endsWith(u8, json, "]"));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"engine/render\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"current_bytes\":96") != null);

    render.allocator().free(bytes);
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, render.deinit());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, engine.deinit());
    try std.testing.expectEqual(Runtime.DeinitStatus.ok, audio.deinit());
    try std.testing.expectEqual(@as(usize, 0), runtime_mod.zoneCount());
}

test "zone budget and hardcap still work" {
    const TestZone = Zone(.{ .name = "limited", .budget = 100, .hardcap = 200 });
    if (TestZone.effective_mode == .off) return error.SkipZigTest;
    var zone = try TestZone.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    defer std.debug.assert(zone.deinit() == .ok);
    const ally = zone.allocator();

    const a = try ally.alloc(u8, 150);
    defer ally.free(a);
    try std.testing.expectEqual(@as(f32, 150.0), zone.budgetPercent());
    try std.testing.expectEqual(@as(f32, 75.0), zone.hardcapPercent());

    try std.testing.expectError(error.OutOfMemory, ally.alloc(u8, 100));
}

test "zone frame tracking still works" {
    const TestZone = Zone(.{ .name = "frames", .frame_tracking = true });
    if (TestZone.effective_mode != .full) return error.SkipZigTest;
    var zone = try TestZone.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    defer std.debug.assert(zone.deinit() == .ok);
    const ally = zone.allocator();

    zone.markFrame();
    const a = try ally.alloc(u8, 64);
    defer ally.free(a);
    zone.markFrame();

    try std.testing.expectEqual(@as(i64, 64), zone.frameDelta());
    try std.testing.expectEqual(@as(usize, 1), zone.frameAllocs());
}

test "off mode returns backing allocator directly" {
    const TestZone = Zone(.{ .name = "off" });
    if (TestZone.effective_mode != .off) return error.SkipZigTest;

    var zone = try TestZone.init(.{
        .backing_allocator = std.testing.allocator,
        .control_allocator = std.testing.allocator,
    });
    defer std.debug.assert(zone.deinit() == .ok);

    const ally = zone.allocator();
    try std.testing.expectEqual(std.testing.allocator.ptr, ally.ptr);
}
