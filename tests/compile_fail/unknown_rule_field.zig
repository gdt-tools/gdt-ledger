const ledger = @import("gdt_ledger");

pub const gdt_ledger_options = .{
    .default_mode = .off,
    .rules = .{
        .{ .scope = "gdt_vulkan", .level = .full },
    },
};

pub fn main() void {
    const Zone = ledger.Zone(.{ .name = "typo" });
    _ = Zone.effective_mode;
}
