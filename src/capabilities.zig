//! Maps an effective `LedgerMode` (plus the zone's config) to the concrete
//! feature set the zone compiles in. The single source of truth for "what does
//! this mode turn on", consumed by the zone factory to drive void elimination
//! per field: a `false` capability means the backing state is `void`.

const std = @import("std");

const ZoneConfig = @import("config/zone.zig");
const LedgerMode = @import("policy.zig").LedgerMode;

/// The features a zone compiles in, derived once at comptime from its mode and
/// config. Each `false` field is a void-eliminated piece of zone state.
pub const Capabilities = struct {
    /// Live-byte, peak, and alloc/free counters.
    stats: bool,
    /// Hard ceiling enforcement; on only when `config.hardcap > 0`.
    hardcap: bool,
    /// Per-frame allocation deltas; on only under `.full` with
    /// `config.frame_tracking`.
    frames: bool,
    /// Double-deinit and leak detection on the zone handle.
    lifecycle: bool,
    /// Registration in the global runtime registry so dumps can see the zone;
    /// on only under `.full`.
    runtime_export: bool,
};

/// Resolve the feature set for `mode` and `config`. Pure comptime mapping:
/// `.off` enables nothing, `.guardrails` enables counters, hardcap, and
/// lifecycle, `.full` adds frames and runtime export. `hardcap` and `frames`
/// additionally require their config field, so a `.full` zone with
/// `frame_tracking = false` still compiles frames out.
pub fn resolve(comptime mode: LedgerMode, comptime config: ZoneConfig) Capabilities {
    return switch (mode) {
        .off => .{
            .stats = false,
            .hardcap = false,
            .frames = false,
            .lifecycle = false,
            .runtime_export = false,
        },
        .guardrails => .{
            .stats = true,
            .hardcap = config.hardcap > 0,
            .frames = false,
            .lifecycle = true,
            .runtime_export = false,
        },
        .full => .{
            .stats = true,
            .hardcap = config.hardcap > 0,
            .frames = config.frame_tracking,
            .lifecycle = true,
            .runtime_export = true,
        },
    };
}

test "capabilities map modes to implementation features" {
    const requested_frames = ZoneConfig{ .name = "zone", .hardcap = 128, .frame_tracking = true };

    const off = resolve(.off, requested_frames);
    try std.testing.expect(!off.stats);
    try std.testing.expect(!off.hardcap);
    try std.testing.expect(!off.frames);
    try std.testing.expect(!off.lifecycle);
    try std.testing.expect(!off.runtime_export);

    const guardrails = resolve(.guardrails, requested_frames);
    try std.testing.expect(guardrails.stats);
    try std.testing.expect(guardrails.hardcap);
    try std.testing.expect(!guardrails.frames);
    try std.testing.expect(guardrails.lifecycle);
    try std.testing.expect(!guardrails.runtime_export);

    const full = resolve(.full, requested_frames);
    try std.testing.expect(full.stats);
    try std.testing.expect(full.hardcap);
    try std.testing.expect(full.frames);
    try std.testing.expect(full.lifecycle);
    try std.testing.expect(full.runtime_export);
}
