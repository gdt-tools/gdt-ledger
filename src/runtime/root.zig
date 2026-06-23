//! Runtime registry for live `.full` zones, and the facade for the runtime
//! family.
//!
//! Owns the intrusive node list that dumps walk, the per-zone `Export` handle,
//! and the snapshot/dump entry points. Storage is app-owned: the root declares
//! `pub var gdt_ledger_runtime: ledger.RootRuntime = .{}` and the registry reads
//! it structurally via `@import("root")`, so multiple module instances share one
//! list. Only `.full` zones register here; `.guardrails`/`.off` zones never
//! touch it. Formatting lives in `dump.zig`.
//!
//! Thread-safety: the list is guarded by a spinlock in `RootRuntime`. The
//! per-zone counters a snapshot reads are not under that lock, so a snapshot row
//! can be internally skewed under live mutation -- it is a reporting view, not a
//! transactional one.

const std = @import("std");
const builtin = @import("builtin");

const root = @import("root");
const dump = @import("dump.zig");

/// Outcome of a zone `deinit`. `.ok`: clean. `.leak`: live bytes remained.
/// `.live_children`: a subzone is still alive -- non-destructive, so deinit the
/// children and retry.
pub const DeinitStatus = enum {
    ok,
    leak,
    live_children,
};

/// One zone's stats as captured for a dump or snapshot: a plain runtime record,
/// copied by value out of each zone's `query`, not the zone itself.
pub const ZoneInfo = struct {
    /// Stable identity for this run: the address of the zone's export node.
    id: usize,
    /// `id` of the parent zone, or null for a root.
    parent_id: ?usize,

    /// Full scope path, e.g. "engine/render".
    name: []const u8,
    /// Trailing path segment only, e.g. "render".
    local_name: []const u8,
    /// Parent's full path, or null for a root.
    parent_name: ?[]const u8,

    /// Depth below the root (0 for a root zone).
    depth: usize,

    current_bytes: usize,
    peak_bytes: usize,

    allocation_count: usize,
    deallocation_count: usize,

    budget: usize,
    budget_percent: f32,

    hardcap: usize,
    hardcap_percent: f32,

    frame_delta: i64 = 0,
    frame_allocs: usize = 0,
    frame_frees: usize = 0,

    /// Whether this is a root zone (no parent).
    pub fn isRoot(self: ZoneInfo) bool {
        return self.parent_id == null;
    }
};

/// Intrusive doubly-linked list node embedded in each `Export`. `extern` so its
/// layout is identical across module instances that share one registry. The
/// `query_fn`/`ctx` pair lets the registry pull a `ZoneInfo` without knowing the
/// concrete zone type.
pub const NodeHeader = extern struct {
    next: ?*anyopaque,
    prev: ?*anyopaque,
    parent: ?*anyopaque,
    ctx: *anyopaque,
    query_fn: *const anyopaque,
};

/// Per-zone registry handle embedded in a `.full` zone core. Holds the list
/// node and a link to the parent export so a dump can rebuild the hierarchy;
/// `runtime_linked` tracks whether the node is currently in the list.
pub const Export = struct {
    node: NodeHeader = .{
        .next = null,
        .prev = null,
        .parent = null,
        .ctx = undefined,
        .query_fn = undefined,
    },
    parent: ?*Export,
    runtime_linked: bool = false,
};

/// App-owned registry storage. Declare it in the root as
/// `pub var gdt_ledger_runtime: ledger.RootRuntime = .{}`; the library finds it
/// structurally. Holds the intrusive list head/tail, the live count, and the
/// spinlock guarding all three. Zero-initialized is an empty registry.
pub const RootRuntime = struct {
    head: ?*anyopaque = null,
    tail: ?*anyopaque = null,
    zone_count: usize = 0,
    lock: std.atomic.Value(u8) = .init(0),
};

var test_runtime: RootRuntime = .{};

/// Assert that the app declared runtime storage. In a non-test build a missing
/// `gdt_ledger_runtime` is a `@compileError` naming the fix; test builds fall
/// back to internal storage. When storage is present, its shape is validated at
/// comptime.
pub fn requireRuntime() void {
    if (comptime !@hasDecl(root, "gdt_ledger_runtime")) {
        if (comptime !builtin.is_test) {
            @compileError("gdt-ledger: .full requires root.gdt_ledger_runtime -- declare `pub var gdt_ledger_runtime: ledger.RootRuntime = .{};` in your root file");
        }
        return;
    }
    comptime validateRuntimeStorage();
}

// NOTE(multi-instance): same philosophy as policy.validateOptions -- runtime
// storage is read structurally via @import("root"), which is typo- and
// type-silent by default, so the shape gets an explicit friendly check
// here instead of letting a wrong decl explode inside lockRuntime with
// "no field named 'lock'".
fn validateRuntimeStorage() void {
    const T = @TypeOf(root.gdt_ledger_runtime);
    if (@typeInfo(T) != .@"struct" or
        !@hasField(T, "head") or !@hasField(T, "tail") or
        !@hasField(T, "zone_count") or !@hasField(T, "lock"))
    {
        @compileError("gdt-ledger: root.gdt_ledger_runtime must be a ledger.RootRuntime (found '" ++ @typeName(T) ++ "')");
    }
    if (@typeInfo(@TypeOf(&root.gdt_ledger_runtime)).pointer.is_const) {
        @compileError("gdt-ledger: root.gdt_ledger_runtime must be declared 'pub var', not 'pub const' -- the registry mutates it");
    }
}

/// Initialize an export handle with its parent link, unlinked. Pairs with
/// `link` once the zone is ready to appear in dumps.
pub fn initExport(node_export: *Export, parent: ?*Export) void {
    node_export.* = .{
        .parent = parent,
        .runtime_linked = false,
    };
}

/// Add this zone's node to the registry list, wiring its parent pointer to the
/// parent's node (when the parent is itself linked) and recording the
/// `query_fn`/`ctx` the registry calls to read the zone's stats. Takes the
/// registry lock.
pub fn link(node_export: *Export, ctx: *anyopaque, query_fn: anytype) void {
    requireRuntime();

    node_export.node = .{
        .next = null,
        .prev = null,
        .parent = if (node_export.parent) |parent| (if (parent.runtime_linked) &parent.node else null) else null,
        .ctx = ctx,
        .query_fn = @ptrCast(query_fn),
    };
    node_export.runtime_linked = true;

    lockRuntime();
    defer unlockRuntime();

    appendNodeUnlocked(runtimePtr(), &node_export.node);
}

/// Remove this zone's node from the registry list. No-op if it was never
/// linked. Takes the registry lock.
pub fn unlink(node_export: *Export) void {
    if (!node_export.runtime_linked) return;

    lockRuntime();
    defer unlockRuntime();

    removeNodeUnlocked(runtimePtr(), &node_export.node);
    node_export.runtime_linked = false;
}

/// Number of live registered zones. 0 when no runtime storage exists -- every
/// zone `.off`/`.guardrails`, or no `gdt_ledger_runtime` in the root.
pub fn zoneCount() usize {
    if (comptime !hasRuntimeStorage()) return 0;

    lockRuntime();
    defer unlockRuntime();

    return runtimePtr().zone_count;
}

/// Clear the registry list for test isolation. Panics if any zone is still
/// live: it does not unlink zones, so resetting with live zones would leave them
/// pointing into a list they are no longer in. Intended for tests only.
pub fn unsafeResetForTest() void {
    if (comptime !hasRuntimeStorage()) return;

    lockRuntime();
    defer unlockRuntime();

    const rt = runtimePtr();
    if (rt.zone_count != 0) {
        @panic("gdt-ledger: unsafeResetForTest called with live runtime zones");
    }

    rt.head = null;
    rt.tail = null;
    rt.zone_count = 0;
}

/// Fixed capacity of a `Snapshot`. Beyond this, collection stops and
/// `Snapshot.overflowed` is set.
pub const max_snapshot_zones = 1024;

/// A point-in-time copy of the registered zones, pre-order (parent before
/// child). Fixed capacity; see `overflowed`.
pub const Snapshot = struct {
    /// Captured zone records, valid over `infos[0..len]`.
    infos: [max_snapshot_zones]ZoneInfo = undefined,
    /// Number of valid entries in `infos`.
    len: usize = 0,
    /// Set when the registry held more than `max_snapshot_zones` zones and some
    /// were dropped from this snapshot.
    overflowed: bool = false,
};

/// Capture all registered zones into a `Snapshot`, ordered parent-before-child
/// so a dump reads top-down. Takes the registry lock to walk the list, but each
/// zone's counters are read without further locking, so a row can be internally
/// skewed under concurrent mutation. Returns an empty snapshot when no runtime
/// storage exists.
pub fn snapshot() Snapshot {
    var result: Snapshot = .{};
    if (comptime !hasRuntimeStorage()) return result;

    lockRuntime();
    defer unlockRuntime();

    var flat: [max_snapshot_zones]ZoneInfo = undefined;
    var flat_len: usize = 0;

    var cursor = runtimePtr().head;
    while (cursor) |opaque_node| {
        if (flat_len >= flat.len) {
            result.overflowed = true;
            break;
        }
        const header = asNode(opaque_node);
        // NOTE(abi): deliberate bet -- NodeHeader is extern for
        // cross-module-instance layout, but query_fn returns instance-local
        // ZoneInfo BY VALUE through this cast, and ZoneInfo (slices,
        // optionals) has unspecified layout. Structurally identical structs
        // get identical layout within one compilation, which is the only
        // place multiple gdt_ledger module instances can meet, so this
        // holds; making ZoneInfo extern would cost the slices/optionals.
        const query_fn: *const fn (*const anyopaque) ZoneInfo = @ptrCast(@alignCast(header.query_fn));
        flat[flat_len] = query_fn(header.ctx);
        flat_len += 1;
        cursor = header.next;
    }

    appendPreOrder(flat[0..flat_len], &result.infos, &result.len, &result.overflowed, null);

    for (flat[0..flat_len]) |info| {
        if (containsId(result.infos[0..result.len], info.id)) continue;
        if (result.len >= result.infos.len) {
            result.overflowed = true;
            break;
        }

        result.infos[result.len] = info;
        result.len += 1;
        appendPreOrder(flat[0..flat_len], &result.infos, &result.len, &result.overflowed, info.id);
    }

    return result;
}

pub const dumpToWriter = dump.dumpToWriter;
pub const dumpToJson = dump.dumpToJson;

fn RuntimeStorage() type {
    if (@hasDecl(root, "gdt_ledger_runtime")) {
        return @TypeOf(root.gdt_ledger_runtime);
    }
    return RootRuntime;
}

fn hasRuntimeStorage() bool {
    return @hasDecl(root, "gdt_ledger_runtime") or builtin.is_test;
}

// The active registry storage: the app's `gdt_ledger_runtime` when declared,
// otherwise a file-local fallback that only exists in test builds.
fn runtimePtr() *RuntimeStorage() {
    if (comptime @hasDecl(root, "gdt_ledger_runtime")) {
        return &root.gdt_ledger_runtime;
    } else {
        return &test_runtime;
    }
}

fn lockRuntime() void {
    const rt = runtimePtr();
    while (rt.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockRuntime() void {
    runtimePtr().lock.store(0, .release);
}

fn appendNodeUnlocked(rt: anytype, header: *NodeHeader) void {
    header.prev = rt.tail;
    header.next = null;

    if (rt.tail) |tail| {
        asNode(tail).next = header;
    } else {
        rt.head = header;
    }

    rt.tail = header;
    rt.zone_count += 1;
}

// Unlink a node that is asserted to be a current list member: a non-empty list
// and actual membership are checked first, so a double-unlink or a stale node
// faults here instead of silently underflowing zone_count or corrupting links.
fn removeNodeUnlocked(rt: anytype, header: *NodeHeader) void {
    std.debug.assert(rt.zone_count > 0);
    std.debug.assert(containsNodeUnlocked(rt, header));

    if (header.prev) |prev| {
        asNode(prev).next = header.next;
    } else {
        rt.head = header.next;
    }

    if (header.next) |next| {
        asNode(next).prev = header.prev;
    } else {
        rt.tail = header.prev;
    }

    rt.zone_count -= 1;
    header.prev = null;
    header.next = null;
}

fn containsNodeUnlocked(rt: anytype, header: *NodeHeader) bool {
    var cursor = rt.head;
    while (cursor) |opaque_node| {
        const node = asNode(opaque_node);
        if (node == header) return true;
        cursor = node.next;
    }
    return false;
}

fn asNode(ptr: *anyopaque) *NodeHeader {
    return @ptrCast(@alignCast(ptr));
}

fn containsId(snapshot_infos: []const ZoneInfo, id: usize) bool {
    for (snapshot_infos) |info| {
        if (info.id == id) return true;
    }
    return false;
}

fn appendPreOrder(
    flat: []const ZoneInfo,
    ordered: *[max_snapshot_zones]ZoneInfo,
    ordered_len: *usize,
    overflowed: *bool,
    parent_id: ?usize,
) void {
    for (flat) |info| {
        if (info.parent_id != parent_id) continue;
        if (ordered_len.* >= ordered.len) {
            overflowed.* = true;
            return;
        }

        ordered[ordered_len.*] = info;
        ordered_len.* += 1;
        appendPreOrder(flat, ordered, ordered_len, overflowed, info.id);
    }
}
