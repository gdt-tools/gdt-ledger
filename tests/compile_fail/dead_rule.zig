const ledger = @import("gdt_ledger");

comptime {
    ledger.validateRules(.{
        .default_mode = .guardrails,
        .rules = .{
            .{ .scope = "gdt_vulcan", .mode = .full },
        },
    }, &.{ "gdt_vulkan/upload", "gdt_audio" });
}

pub fn main() void {}
