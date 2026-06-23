const ledger = @import("gdt_ledger");

pub const gdt_ledger_options = .{
    .defualt_mode = .full,
};

pub fn main() void {
    const Zone = ledger.Zone(.{ .name = "typo" });
    _ = Zone.effective_mode;
}
