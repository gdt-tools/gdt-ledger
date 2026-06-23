//! Shared simple-mode test runner logic for the per-mode runners.
//!
//! NOTE(build): in a `b.addTest` build, `@import("root")` resolves to the TEST
//! RUNNER module, not the module under test -- so root-policy declarations
//! (`gdt_ledger_options`) must live in the runner. The default (server-mode)
//! runner can't carry them, hence the small per-mode runners around this file.
//! Declaring the policy on the tested module
//! instead means the library never sees it and every mode step silently
//! runs `.off`.
const std = @import("std");
const builtin = @import("builtin");

pub fn runTests() !void {
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;

    for (builtin.test_functions) |t| {
        std.testing.allocator_instance = .{};
        const result = t.func();
        if (std.testing.allocator_instance.deinit() == .leak) {
            leaked += 1;
            std.debug.print("LEAK: {s}\n", .{t.name});
        }
        if (result) |_| {
            passed += 1;
        } else |err| switch (err) {
            error.SkipZigTest => skipped += 1,
            else => {
                failed += 1;
                std.debug.print("FAIL: {s}: {}\n", .{ t.name, err });
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }

    std.debug.print("{d} passed, {d} skipped, {d} failed, {d} leaked ({d} total)\n", .{
        passed, skipped, failed, leaked, builtin.test_functions.len,
    });
    if (failed != 0 or leaked != 0) return error.TestsFailed;
}
