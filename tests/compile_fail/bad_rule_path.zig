const ledger = @import("gdt_ledger");

pub const gdt_ledger_options = .{
    .default_mode = .guardrails,
    .rules = .{
        .{ .scope = "gdt_vulkan//upload", .mode = .full },
    },
};

pub fn main() void {
    const Vulkan = ledger.scope("gdt_vulkan");
    const Zone = Vulkan.Zone(.{ .name = "upload" });
    _ = Zone.effective_mode;
}
