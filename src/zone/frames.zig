//! Per-frame allocation deltas: bytes / allocs / frees since the last `mark`.
//!
//! `FrameStats(enabled, thread_safe)` generates the accumulator a zone embeds;
//! disabled, it is a zero-byte no-op. The published deltas use atomics in
//! thread-safe mode, but the `prev_*` baselines do not: `mark` is a frame-tick
//! operation expected to run on one thread, so concurrent `mark` on one zone is
//! not coherent and callers must serialize it.

const std = @import("std");

/// Generate the frame-delta accumulator for `enabled` / `thread_safe`. Disabled,
/// the returned type is zero-sized and every method is a no-op returning 0.
pub fn FrameStats(comptime enabled: bool, comptime thread_safe: bool) type {
    if (!enabled) {
        return struct {
            pub fn mark(_: *@This(), _: usize, _: usize, _: usize) void {}
            pub fn frameDelta(_: *const @This()) i64 {
                return 0;
            }
            pub fn frameAllocs(_: *const @This()) usize {
                return 0;
            }
            pub fn frameFrees(_: *const @This()) usize {
                return 0;
            }
        };
    }

    const FrameI64 = if (thread_safe) std.atomic.Value(i64) else i64;
    const FrameUsize = if (thread_safe) std.atomic.Value(usize) else usize;

    return struct {
        prev_bytes: usize = 0,
        prev_allocs: usize = 0,
        prev_frees: usize = 0,
        frame_delta: FrameI64 = if (thread_safe) std.atomic.Value(i64).init(0) else 0,
        frame_allocs: FrameUsize = if (thread_safe) std.atomic.Value(usize).init(0) else 0,
        frame_frees: FrameUsize = if (thread_safe) std.atomic.Value(usize).init(0) else 0,

        const Self = @This();

        /// Record the deltas for the frame just ended and roll the baseline
        /// forward to (`current`, `allocs`, `frees`). Byte counts are clamped to
        /// `i64` before subtraction so the signed delta cannot overflow on a
        /// multi-exabyte zone. Not safe against concurrent calls on one instance.
        pub fn mark(self: *Self, current: usize, allocs: usize, frees: usize) void {
            const max_i64 = std.math.maxInt(i64);
            const cur_i64: i64 = @intCast(@min(current, max_i64));
            const prev_i64: i64 = @intCast(@min(self.prev_bytes, max_i64));
            const delta_bytes = cur_i64 - prev_i64;
            const delta_allocs = allocs - self.prev_allocs;
            const delta_frees = frees - self.prev_frees;

            if (thread_safe) {
                self.frame_delta.store(delta_bytes, .monotonic);
                self.frame_allocs.store(delta_allocs, .monotonic);
                self.frame_frees.store(delta_frees, .monotonic);
            } else {
                self.frame_delta = delta_bytes;
                self.frame_allocs = delta_allocs;
                self.frame_frees = delta_frees;
            }

            self.prev_bytes = current;
            self.prev_allocs = allocs;
            self.prev_frees = frees;
        }

        /// Net byte change recorded by the last `mark`.
        pub fn frameDelta(self: *const Self) i64 {
            return if (thread_safe)
                self.frame_delta.load(.monotonic)
            else
                self.frame_delta;
        }

        /// Allocations recorded by the last `mark`.
        pub fn frameAllocs(self: *const Self) usize {
            return if (thread_safe)
                self.frame_allocs.load(.monotonic)
            else
                self.frame_allocs;
        }

        /// Frees recorded by the last `mark`.
        pub fn frameFrees(self: *const Self) usize {
            return if (thread_safe)
                self.frame_frees.load(.monotonic)
            else
                self.frame_frees;
        }
    };
}

test "disabled frame stats are zero-sized no-ops" {
    const Disabled = FrameStats(false, false);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Disabled));

    var stats: Disabled = .{};
    stats.mark(100, 2, 1);
    try std.testing.expectEqual(@as(i64, 0), stats.frameDelta());
    try std.testing.expectEqual(@as(usize, 0), stats.frameAllocs());
    try std.testing.expectEqual(@as(usize, 0), stats.frameFrees());
}

test "enabled frame stats record deltas" {
    const Enabled = FrameStats(true, false);
    var stats: Enabled = .{};

    stats.mark(100, 2, 1);
    try std.testing.expectEqual(@as(i64, 100), stats.frameDelta());
    try std.testing.expectEqual(@as(usize, 2), stats.frameAllocs());
    try std.testing.expectEqual(@as(usize, 1), stats.frameFrees());

    stats.mark(64, 3, 2);
    try std.testing.expectEqual(@as(i64, -36), stats.frameDelta());
    try std.testing.expectEqual(@as(usize, 1), stats.frameAllocs());
    try std.testing.expectEqual(@as(usize, 1), stats.frameFrees());
}
