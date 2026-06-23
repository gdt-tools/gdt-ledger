const std = @import("std");
const ledger = @import("gdt_ledger");

const Vulkan = ledger.scope("gdt_vulkan");

const Cache = Vulkan.Zone(.{ .name = "cache", .hardcap = 32 });
const CacheDetail = Cache.subzone(.{ .name = "detail", .hardcap = 64 });
const Upload = Vulkan.Zone(.{ .name = "upload", .hardcap = 128 });
const UploadScratch = Upload.subzone(.{ .name = "scratch" });

const Audio = ledger.scope("gdt_audio");

const Mix = Audio.Zone(.{ .name = "mix", .hardcap = 256 });
const Render = Audio.Zone(.{ .name = "render", .hardcap = 256 });
const RenderChild = Render.subzone(.{ .name = "child", .hardcap = 128 });

pub fn exercise(gpa: std.mem.Allocator) !void {
    ledger.unsafeResetForTest();

    // Cascade resolution: effective(child) = min(parent, child).
    try expectEqual(@TypeOf(Cache.effective_mode), .off, Cache.effective_mode);
    try expectEqual(@TypeOf(Upload.effective_mode), .full, Upload.effective_mode);
    // Deep .full rule under an .off parent is silently clamped to .off.
    try expectEqual(@TypeOf(CacheDetail.effective_mode), .off, CacheDetail.effective_mode);
    // Explicit .off rule under a .full parent stays .off (hole punched down).
    try expectEqual(@TypeOf(UploadScratch.effective_mode), .off, UploadScratch.effective_mode);
    // .full rule under a guardrails parent is clamped to .guardrails.
    try expectEqual(@TypeOf(Render.effective_mode), .guardrails, Render.effective_mode);
    try expectEqual(@TypeOf(RenderChild.effective_mode), .guardrails, RenderChild.effective_mode);

    var cache = try Cache.init(.{
        .backing_allocator = gpa,
        .control_allocator = gpa,
    });
    var upload = try Upload.init(.{
        .backing_allocator = gpa,
        .control_allocator = gpa,
    });

    try expectEqual(usize, 1, ledger.zoneCount());

    const cache_ally = cache.allocator();
    const cache_bytes = try cache_ally.alloc(u8, 256);
    try expectEqual(usize, 0, cache.currentBytes());
    cache_ally.free(cache_bytes);

    const upload_ally = upload.allocator();
    const upload_bytes = try upload_ally.alloc(u8, 64);
    try expectEqual(usize, 64, upload.currentBytes());
    upload_ally.free(upload_bytes);

    try expectEqual(ledger.DeinitStatus, .ok, upload.deinit());
    try expectEqual(ledger.DeinitStatus, .ok, cache.deinit());
    try expectEqual(usize, 0, ledger.zoneCount());

    try cascadedOffSubtree(gpa);
    try offChildSurvivesEnabledParentDeinit(gpa);
    try clampedChildUnderGuardrailsParent(gpa);
    try scopedFallbackToDefaultMode(gpa);
}

fn cascadedOffSubtree(gpa: std.mem.Allocator) !void {
    ledger.unsafeResetForTest();

    var cache = try Cache.init(.{
        .backing_allocator = gpa,
        .control_allocator = gpa,
    });
    var detail = try CacheDetail.initUnder(.{ .parent = &cache });

    // Whole subtree is off: nothing links into the runtime registry.
    try expectEqual(usize, 0, ledger.zoneCount());

    const ally = detail.allocator();
    const bytes = try ally.alloc(u8, 128);
    try expectEqual(usize, 0, detail.currentBytes());
    ally.free(bytes);

    try expectEqual(ledger.DeinitStatus, .ok, cache.deinit());
    try expectEqual(ledger.DeinitStatus, .ok, detail.deinit());
}

// UAF regression: an off child under an enabled parent used to
// capture parent.allocator() (vtable into the parent's heap impl) without
// lifecycle-attaching, so parent deinit freed the impl and the next child
// alloc segfaulted. The child now captures the root backing by value and
// must survive -- and stay invisible to the parent's stats and hardcap.
fn offChildSurvivesEnabledParentDeinit(gpa: std.mem.Allocator) !void {
    ledger.unsafeResetForTest();

    var upload = try Upload.init(.{
        .backing_allocator = gpa,
        .control_allocator = gpa,
    });
    var scratch = try UploadScratch.initUnder(.{ .parent = &upload });

    const scratch_ally = scratch.allocator();
    const early = try scratch_ally.alloc(u8, 512);
    // Invisible to the parent: no bytes counted, hardcap (128) not consulted.
    try expectEqual(usize, 0, upload.currentBytes());
    scratch_ally.free(early);

    // Off child does not pin the parent.
    try expectEqual(ledger.DeinitStatus, .ok, upload.deinit());
    try expectEqual(usize, 0, ledger.zoneCount());

    // The child keeps allocating from the root backing after parent deinit.
    const late = try scratch_ally.alloc(u8, 64);
    scratch_ally.free(late);
    try expectEqual(ledger.DeinitStatus, .ok, scratch.deinit());
}

fn clampedChildUnderGuardrailsParent(gpa: std.mem.Allocator) !void {
    ledger.unsafeResetForTest();

    var render = try Render.init(.{
        .backing_allocator = gpa,
        .control_allocator = gpa,
    });
    var child = try RenderChild.initUnder(.{ .parent = &render });

    // Both guardrails: no runtime export, but lifecycle still guards deinit.
    try expectEqual(usize, 0, ledger.zoneCount());
    try expectEqual(ledger.DeinitStatus, .live_children, render.deinit());
    try expectEqual(ledger.DeinitStatus, .ok, child.deinit());
    try expectEqual(ledger.DeinitStatus, .ok, render.deinit());
}

fn scopedFallbackToDefaultMode(gpa: std.mem.Allocator) !void {
    ledger.unsafeResetForTest();

    try expectEqual(@TypeOf(Mix.effective_mode), .guardrails, Mix.effective_mode);

    var mix = try Mix.init(.{
        .backing_allocator = gpa,
        .control_allocator = gpa,
    });
    defer std.debug.assert(mix.deinit() == .ok);

    const mix_ally = mix.allocator();
    if (mix_ally.alloc(u8, 512)) |_| {
        return error.ExpectedOutOfMemory;
    } else |err| switch (err) {
        error.OutOfMemory => {},
    }
    try expectEqual(usize, 0, ledger.zoneCount());
}

fn expectEqual(comptime T: type, expected: T, actual: T) !void {
    if (actual != expected) return error.UnexpectedValue;
}
