const ledger = @import("gdt_ledger");

pub const gdt_ledger_options = .{
    .default_mode = .off,
    .rules = .{
        .{ .scope = "gdt_vulkan", .mode = .full },
        .{ .scope = "gdt_vulkan", .mode = .off },
    },
};

pub fn main() void {
    const Zone = ledger.Zone(.{ .name = "dup" });
    _ = Zone.effective_mode;
}
