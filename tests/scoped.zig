const std = @import("std");
const ledger = @import("gdt_ledger");
const scoped_module = @import("scoped_module");

pub const gdt_ledger_options = .{
    .default_mode = .guardrails,
    .rules = .{
        .{ .scope = "gdt_vulkan", .mode = .off },
        .{ .scope = "gdt_vulkan/cache/detail", .mode = .full },
        .{ .scope = "gdt_vulkan/upload", .mode = .full },
        .{ .scope = "gdt_vulkan/upload/scratch", .mode = .off },
        .{ .scope = "gdt_audio/render/child", .mode = .full },
    },
};

pub var gdt_ledger_runtime: ledger.RootRuntime = .{};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const gpa = debug_allocator.allocator();

    try scoped_module.exercise(gpa);
    try unscopedZonesUseDefaultMode(gpa);
}

fn unscopedZonesUseDefaultMode(gpa: std.mem.Allocator) !void {
    ledger.unsafeResetForTest();

    const AppZone = ledger.Zone(.{ .name = "gdt_vulkan", .hardcap = 32 });
    try expectEqual(@TypeOf(AppZone.effective_mode), .guardrails, AppZone.effective_mode);

    var zone = try AppZone.init(.{
        .backing_allocator = gpa,
        .control_allocator = gpa,
    });
    defer std.debug.assert(zone.deinit() == .ok);

    const ally = zone.allocator();
    if (ally.alloc(u8, 64)) |_| {
        return error.ExpectedOutOfMemory;
    } else |err| switch (err) {
        error.OutOfMemory => {},
    }
    try expectEqual(usize, 0, ledger.zoneCount());
}

fn expectEqual(comptime T: type, expected: T, actual: T) !void {
    if (actual != expected) return error.UnexpectedValue;
}
