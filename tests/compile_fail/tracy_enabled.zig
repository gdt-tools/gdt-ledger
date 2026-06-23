const ledger = @import("gdt_ledger");

pub const gdt_ledger_options = .{
    .default_mode = .guardrails,
};

pub fn main() void {
    const Zone = ledger.Zone(.{ .name = "traced", .tracy = true });
    _ = Zone.effective_mode;
}
