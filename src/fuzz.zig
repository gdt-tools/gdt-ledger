const std = @import("std");

const Capabilities = @import("capabilities.zig").Capabilities;
const Runtime = @import("runtime/root.zig");
const TrackedAllocator = @import("accounting/tracked_allocator.zig").TrackedAllocator;
const Meter = @import("accounting/meter.zig").Meter;
const ZoneConfig = @import("config/zone.zig");
const ZoneCore = @import("zone/enabled.zig").ZoneCore;
const runtime_dump = @import("runtime/dump.zig");

const Allocator = std.mem.Allocator;

const max_live_allocs = 16;
const max_alloc_size = 256;
const max_limit_extra = 4096;

const LiveAlloc = struct {
    slice: []u8,
};

const LiveSize = struct {
    len: usize,
};

test "fuzz tracked allocator state machine" {
    try std.testing.fuzz({}, fuzzTrackedAllocator, .{});
}

test "fuzz meter protocol state machine" {
    try std.testing.fuzz({}, fuzzMeterProtocol, .{});
}

test "fuzz zone-core hierarchy accounting" {
    try std.testing.fuzz({}, fuzzZoneCoreHierarchy, .{});
}

test {
    _ = runtime_dump;
}

fn fuzzTrackedAllocator(_: void, smith: *std.testing.Smith) !void {
    const Tracked = TrackedAllocator(.{
        .enable_memory_limit = true,
        .thread_safe = false,
    });

    var state: Tracked.State = .{};
    var promoted = state.promote(std.testing.allocator);
    const ally = promoted.allocator();

    var live: [max_live_allocs]LiveAlloc = undefined;
    var live_count: usize = 0;
    var model: ByteModel = .{};

    model.limit = max_limit_extra;
    state.setMemoryLimit(model.limit);

    defer freeLiveAll(ally, &live, &live_count);

    for (0..96) |_| {
        if (smith.eos()) break;
        switch (smith.value(enum { alloc, free, resize, remap, set_limit })) {
            .alloc => {
                if (live_count == live.len) continue;
                const len = fuzzLen(smith);
                const can_fit = model.current + len <= model.limit;

                const slice = ally.alloc(u8, len) catch |err| {
                    try std.testing.expectEqual(error.OutOfMemory, err);
                    try std.testing.expect(!can_fit);
                    continue;
                };

                try std.testing.expect(can_fit);
                live[live_count] = .{ .slice = slice };
                live_count += 1;
                model.commitAlloc(len);
            },
            .free => {
                if (live_count == 0) continue;
                const index = smith.index(live_count);
                const item = removeLiveAlloc(&live, &live_count, index);
                ally.free(item.slice);
                model.commitFree(item.slice.len);
            },
            .resize => {
                if (live_count == 0) continue;
                const index = smith.index(live_count);
                const old_len = live[index].slice.len;
                const new_len = fuzzLen(smith);
                const can_fit = new_len <= old_len or model.current + (new_len - old_len) <= model.limit;

                if (ally.resize(live[index].slice, new_len)) {
                    try std.testing.expect(can_fit);
                    live[index].slice = live[index].slice.ptr[0..new_len];
                    model.commitResize(old_len, new_len);
                }
            },
            .remap => {
                if (live_count == 0) continue;
                const index = smith.index(live_count);
                const old_len = live[index].slice.len;
                const new_len = fuzzLen(smith);
                const can_fit = new_len <= old_len or model.current + (new_len - old_len) <= model.limit;

                if (ally.remap(live[index].slice, new_len)) |remapped| {
                    try std.testing.expect(can_fit);
                    live[index].slice = remapped;
                    model.commitResize(old_len, new_len);
                }
            },
            .set_limit => {
                model.limit = model.current + @as(usize, smith.valueRangeAtMost(u16, 0, max_limit_extra));
                state.setMemoryLimit(model.limit);
            },
        }

        try expectTrackedState(&state, model, live_count);
    }
}

fn fuzzMeterProtocol(_: void, smith: *std.testing.Smith) !void {
    const Limited = Meter(.{
        .stats = true,
        .hardcap = true,
        .frames = false,
        .lifecycle = false,
        .runtime_export = false,
    }, false);

    var meter: Limited = .{};
    var live: [max_live_allocs]LiveSize = undefined;
    var live_count: usize = 0;
    var model: ByteModel = .{ .limit = max_limit_extra };
    meter.setMemoryLimit(model.limit);

    for (0..128) |_| {
        if (smith.eos()) break;
        switch (smith.value(enum { alloc, free, resize, reserve_rollback, set_limit, overflow_probe })) {
            .alloc => {
                if (live_count == live.len) continue;
                const len = fuzzLen(smith);
                const can_fit = model.current + len <= model.limit;
                const reserved = meter.tryReserve(len);

                if (can_fit) {
                    const total = reserved orelse return error.TestUnexpectedResult;
                    meter.commitAlloc(len, total);
                    live[live_count] = .{ .len = len };
                    live_count += 1;
                    model.commitAlloc(len);
                } else {
                    try std.testing.expect(reserved == null);
                }
            },
            .free => {
                if (live_count == 0) continue;
                const index = smith.index(live_count);
                const item = removeLiveSize(&live, &live_count, index);
                meter.commitFree(item.len);
                model.commitFree(item.len);
            },
            .resize => {
                if (live_count == 0) continue;
                const index = smith.index(live_count);
                const old_len = live[index].len;
                const new_len = fuzzLen(smith);

                if (new_len > old_len) {
                    const delta = new_len - old_len;
                    const can_fit = model.current + delta <= model.limit;
                    const reserved = meter.tryReserve(delta);
                    if (can_fit) {
                        const total = reserved orelse return error.TestUnexpectedResult;
                        meter.commitResize(old_len, new_len, total);
                        live[index].len = new_len;
                        model.commitResize(old_len, new_len);
                    } else {
                        try std.testing.expect(reserved == null);
                    }
                } else {
                    meter.commitResize(old_len, new_len, 0);
                    live[index].len = new_len;
                    model.commitResize(old_len, new_len);
                }
            },
            .reserve_rollback => {
                const len = fuzzLen(smith);
                const can_fit = model.current + len <= model.limit;
                const reserved = meter.tryReserve(len);
                if (can_fit) {
                    try std.testing.expect(reserved != null);
                    meter.rollbackReserve(len);
                } else {
                    try std.testing.expect(reserved == null);
                }
            },
            .set_limit => {
                model.limit = model.current + @as(usize, smith.valueRangeAtMost(u16, 0, max_limit_extra));
                meter.setMemoryLimit(model.limit);
            },
            .overflow_probe => {
                meter.setMemoryLimit(std.math.maxInt(usize));
                const reserved = meter.tryReserve(std.math.maxInt(usize));
                if (model.current == 0) {
                    try std.testing.expect(reserved != null);
                    meter.rollbackReserve(std.math.maxInt(usize));
                } else {
                    try std.testing.expect(reserved == null);
                }
                meter.setMemoryLimit(model.limit);
            },
        }

        try expectMeterState(&meter, model, live_count);
    }
}

const CoreCaps = Capabilities{
    .stats = true,
    .hardcap = false,
    .frames = false,
    .lifecycle = true,
    .runtime_export = false,
};

const ParentDef = struct {
    pub const config = ZoneConfig{ .name = "parent", .thread_safe = false };
    pub const capabilities = CoreCaps;
    pub const zone_name = "parent";
    pub const zone_local_name = "parent";
    pub const parent_name: ?[]const u8 = null;
    pub const depth = 0;
};

const ChildDef = struct {
    pub const config = ZoneConfig{ .name = "parent/child", .thread_safe = false };
    pub const capabilities = CoreCaps;
    pub const zone_name = "parent/child";
    pub const zone_local_name = "child";
    pub const parent_name: ?[]const u8 = "parent";
    pub const depth = 1;
};

fn fuzzZoneCoreHierarchy(_: void, smith: *std.testing.Smith) !void {
    const ParentCore = ZoneCore(ParentDef);
    const ChildCore = ZoneCore(ChildDef);

    const backing = std.testing.allocator;
    const control = std.testing.allocator;
    var parent = try ParentCore.create(backing, control, backing, null);
    var child = try ChildCore.create(parent.allocator(), parent.controlAllocator(), parent.rootBackingAllocator(), parent.parentRef());

    var parent_live: [max_live_allocs]LiveAlloc = undefined;
    var child_live: [max_live_allocs]LiveAlloc = undefined;
    var parent_live_count: usize = 0;
    var child_live_count: usize = 0;
    var model: HierarchyModel = .{};

    defer {
        freeLiveAll(parent.allocator(), &parent_live, &parent_live_count);
        freeLiveAll(child.allocator(), &child_live, &child_live_count);
        std.debug.assert(child.deinit() == .ok);
        std.debug.assert(parent.deinit() == .ok);
    }

    for (0..96) |_| {
        if (smith.eos()) break;
        switch (smith.value(enum { alloc_parent, alloc_child, free_parent, free_child, probe_live_child })) {
            .alloc_parent => {
                if (parent_live_count == parent_live.len) continue;
                const len = @as(usize, smith.valueRangeAtMost(u16, 1, 128));
                const slice = try parent.allocator().alloc(u8, len);
                parent_live[parent_live_count] = .{ .slice = slice };
                parent_live_count += 1;
                model.allocParent(len);
            },
            .alloc_child => {
                if (child_live_count == child_live.len) continue;
                const len = @as(usize, smith.valueRangeAtMost(u16, 1, 128));
                const slice = try child.allocator().alloc(u8, len);
                child_live[child_live_count] = .{ .slice = slice };
                child_live_count += 1;
                model.allocChild(len);
            },
            .free_parent => {
                if (parent_live_count == 0) continue;
                const index = smith.index(parent_live_count);
                const item = removeLiveAlloc(&parent_live, &parent_live_count, index);
                parent.allocator().free(item.slice);
                model.freeParent(item.slice.len);
            },
            .free_child => {
                if (child_live_count == 0) continue;
                const index = smith.index(child_live_count);
                const item = removeLiveAlloc(&child_live, &child_live_count, index);
                child.allocator().free(item.slice);
                model.freeChild(item.slice.len);
            },
            .probe_live_child => {
                if (child_live_count != 0) {
                    try std.testing.expectEqual(Runtime.DeinitStatus.live_children, parent.deinit());
                }
            },
        }

        try expectHierarchyState(parent, child, model, parent_live_count, child_live_count);
    }
}

const ByteModel = struct {
    current: usize = 0,
    peak: usize = 0,
    allocs: usize = 0,
    frees: usize = 0,
    limit: usize = std.math.maxInt(usize),

    fn commitAlloc(self: *ByteModel, len: usize) void {
        self.current += len;
        self.peak = @max(self.peak, self.current);
        self.allocs += 1;
    }

    fn commitFree(self: *ByteModel, len: usize) void {
        self.current -= len;
        self.frees += 1;
    }

    fn commitResize(self: *ByteModel, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            self.current += new_len - old_len;
            self.peak = @max(self.peak, self.current);
        } else {
            self.current -= old_len - new_len;
        }
    }
};

const HierarchyModel = struct {
    parent_direct: ByteModel = .{},
    child: ByteModel = .{},

    fn allocParent(self: *HierarchyModel, len: usize) void {
        self.parent_direct.commitAlloc(len);
    }

    fn allocChild(self: *HierarchyModel, len: usize) void {
        self.child.commitAlloc(len);
    }

    fn freeParent(self: *HierarchyModel, len: usize) void {
        self.parent_direct.commitFree(len);
    }

    fn freeChild(self: *HierarchyModel, len: usize) void {
        self.child.commitFree(len);
    }

    fn parentCurrent(self: HierarchyModel) usize {
        return self.parent_direct.current + self.child.current;
    }

    fn parentAllocs(self: HierarchyModel) usize {
        return self.parent_direct.allocs + self.child.allocs;
    }

    fn parentFrees(self: HierarchyModel) usize {
        return self.parent_direct.frees + self.child.frees;
    }
};

fn fuzzLen(smith: *std.testing.Smith) usize {
    return @as(usize, smith.valueRangeAtMost(u16, 1, max_alloc_size));
}

fn removeLiveAlloc(live: *[max_live_allocs]LiveAlloc, live_count: *usize, index: usize) LiveAlloc {
    const item = live[index];
    live_count.* -= 1;
    live[index] = live[live_count.*];
    return item;
}

fn removeLiveSize(live: *[max_live_allocs]LiveSize, live_count: *usize, index: usize) LiveSize {
    const item = live[index];
    live_count.* -= 1;
    live[index] = live[live_count.*];
    return item;
}

fn freeLiveAll(ally: Allocator, live: *[max_live_allocs]LiveAlloc, live_count: *usize) void {
    while (live_count.* != 0) {
        const item = removeLiveAlloc(live, live_count, live_count.* - 1);
        ally.free(item.slice);
    }
}

fn expectTrackedState(state: anytype, model: ByteModel, live_count: usize) !void {
    try std.testing.expectEqual(model.current, state.currentBytes());
    try std.testing.expectEqual(model.peak, state.peakBytes());
    try std.testing.expectEqual(model.allocs, state.allocationCount());
    try std.testing.expectEqual(model.frees, state.deallocationCount());
    try std.testing.expectEqual(live_count, state.allocationCount() - state.deallocationCount());
    try std.testing.expect(state.currentBytes() <= model.limit);
}

fn expectMeterState(meter: anytype, model: ByteModel, live_count: usize) !void {
    try std.testing.expectEqual(model.current, meter.currentBytes());
    try std.testing.expectEqual(model.peak, meter.peakBytes());
    try std.testing.expectEqual(model.allocs, meter.allocationCount());
    try std.testing.expectEqual(model.frees, meter.deallocationCount());
    try std.testing.expectEqual(live_count, meter.allocationCount() - meter.deallocationCount());
    try std.testing.expect(meter.currentBytes() <= model.limit);
}

fn expectHierarchyState(parent: anytype, child: anytype, model: HierarchyModel, parent_live_count: usize, child_live_count: usize) !void {
    try std.testing.expectEqual(model.parentCurrent(), parent.currentBytes());
    try std.testing.expectEqual(model.child.current, child.currentBytes());

    try std.testing.expectEqual(model.parentAllocs(), parent.allocationCount());
    try std.testing.expectEqual(model.parentFrees(), parent.deallocationCount());
    try std.testing.expectEqual(model.child.allocs, child.allocationCount());
    try std.testing.expectEqual(model.child.frees, child.deallocationCount());

    try std.testing.expectEqual(parent_live_count + child_live_count, parent.allocationCount() - parent.deallocationCount());
    try std.testing.expectEqual(child_live_count, child.allocationCount() - child.deallocationCount());
}
