const ledger = @import("gdt_ledger");

pub const gdt_ledger_options = .{
    .default_mode = .full,
};

pub fn main() !void {
    const Zone = ledger.Zone(.{ .name = "app" });
    var zone = try Zone.init(.{
        .backing_allocator = undefined,
        .control_allocator = undefined,
    });
    _ = &zone;
}
