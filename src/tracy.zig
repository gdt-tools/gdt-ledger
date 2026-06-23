//! Tracy profiler hooks (stub).
//!
//! Every hook compiles to nothing while `enabled` is false. The hooks exist so
//! the zone allocation paths already carry call sites; turning them into real
//! Tracy events later is a one-line flip plus the C API binding, with no churn
//! in the allocators that call them.

/// Compile-time switch for the Tracy hooks. While false, each hook below is
/// eliminated and the library pulls in no profiler dependency.
pub const enabled = false;

/// Report a named allocation to Tracy. No-op while `enabled` is false.
pub inline fn allocNamed(ptr: [*]u8, len: usize, zone_name: [:0]const u8) void {
    if (!enabled) return;

    _ = ptr;
    _ = len;
    _ = zone_name;
}

/// Report a named free to Tracy. No-op while `enabled` is false.
pub inline fn freeNamed(ptr: [*]const u8, zone_name: [:0]const u8) void {
    if (!enabled) return;

    _ = ptr;
    _ = zone_name;
}

test "tracy stubs compile and are no-ops" {
    var buf: [1]u8 = .{42};
    allocNamed(&buf, 1, "test");
    freeNamed(&buf, "test");
}
