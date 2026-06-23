const ledger = @import("gdt_ledger");

pub const gdt_ledger_options = .{
    .default_mode = .guardrails,
};

pub fn main() void {
    const Parent = ledger.Zone(.{ .name = "parent" });
    const Child = Parent.subzone(.{ .name = "child" });
    const Wrapped = ledger.ZonedFixedBuffer(Child);
    _ = Wrapped;
}
