//! Root-zone configuration: the comptime argument to `ledger.Zone(...)`.
//!
//! Every field changes what the generated zone compiles in, so each is part of
//! the public API. Disabled features are void-eliminated, not runtime-branched.
//! Effective behavior is still gated by the zone's mode (see `capabilities`): a
//! field requested here is compiled out if the mode does not enable it.

const builtin = @import("builtin");

const ZoneConfig = @This();

/// Zone name, also its scope-path segment for rule matching. Non-empty and
/// JSON-safe (no '"', '\\', or control characters); validated at comptime.
name: []const u8,
/// Informational soft limit in bytes (0 = no budget tracking). `budgetPercent()`
/// may exceed 100%: a budget is a gauge to watch, not a ceiling that rejects.
budget: usize = 0,
/// Hard ceiling in bytes (0 = unlimited). An allocation that would cross it
/// fails with `error.OutOfMemory`; the offender is denied, not the whole heap.
hardcap: usize = 0,
/// Track per-frame allocation deltas. The frame counters are void when off, and
/// also when the mode is below `.full`.
frame_tracking: bool = false,
/// Reserved for future Tracy per-allocation instrumentation. Setting it true is
/// rejected at comptime until that path exists.
tracy: bool = false,
/// Make ledger counters and hardcap reservation atomic -- nothing more. It does
/// not synchronize the backing allocator, wrapper-owned allocator state, or
/// concurrent `markFrame()` calls; those need a thread-safe backing allocator or
/// external locking.
thread_safe: bool = !builtin.single_threaded,
