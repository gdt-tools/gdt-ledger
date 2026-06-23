//! Low-level configuration for `TrackedAllocator`, the metering allocator a zone
//! wraps around its backing allocator.
//!
//! A zone derives this from its mode and `ZoneConfig`; it is rarely written by
//! hand. Each `false` flag void-eliminates the matching counters, so a fully
//! disabled tracker has zero-byte state.

const builtin = @import("builtin");

const TrackedConfig = @This();

/// Enforce the hardcap on every reservation. The limit field is void when false.
enable_memory_limit: bool = false,

/// Keep live/peak/count statistics. Those counters are void when false.
enable_stats: bool = true,

/// Use atomic counter updates instead of plain reads/writes. Covers the tracker's
/// own counters and hardcap reservation, not the backing allocator.
thread_safe: bool = !builtin.single_threaded,
