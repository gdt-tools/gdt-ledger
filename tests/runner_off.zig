//! Off-mode test runner; see test_runner.zig for why the policy must live here.
pub const gdt_ledger_options = .{
    .default_mode = .off,
};

pub fn main() !void {
    try @import("test_runner.zig").runTests();
}
