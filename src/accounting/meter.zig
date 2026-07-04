//! Per-zone counter block: live bytes, peak, alloc/free counts, and the optional
//! hardcap reservation.
//!
//! `Meter(caps, thread_safe)` generates the struct a zone embeds; each disabled
//! counter is `void`, so a fully-off meter is zero bytes. Thread-safe meters use
//! atomics with `.monotonic` ordering throughout -- these are statistics, not
//! synchronization primitives, so they never order other memory. The hardcap
//! path is a lock-free reserve/commit/rollback protocol: `tryReserve` claims
//! space (or rejects), then exactly one of `commitAlloc` / `commitResize` /
//! `rollbackReserve` resolves the claim.

const std = @import("std");

const Capabilities = @import("../capabilities.zig").Capabilities;

/// Generate a meter type for the given capabilities and thread-safety.
///
/// `caps` selects which counters exist (each disabled one becomes `void`);
/// `thread_safe` selects atomic versus plain integer ops. Hardcap enforcement
/// reads `current_bytes`, so `caps.hardcap` without `caps.stats` is a
/// `@compileError`.
pub fn Meter(comptime caps: Capabilities, comptime thread_safe: bool) type {
    comptime {
        if (caps.hardcap and !caps.stats) {
            @compileError("Meter: hardcap requires stats (current_bytes needed for limit checks)");
        }
    }

    const is_atomic = thread_safe;

    const StatInt = if (caps.stats)
        (if (is_atomic) std.atomic.Value(usize) else usize)
    else
        void;

    const LimitInt = if (caps.hardcap)
        (if (is_atomic) std.atomic.Value(usize) else usize)
    else
        void;

    return struct {
        current_bytes: StatInt = if (caps.stats)
            (if (is_atomic) std.atomic.Value(usize).init(0) else 0)
        else {},

        peak_bytes: StatInt = if (caps.stats)
            (if (is_atomic) std.atomic.Value(usize).init(0) else 0)
        else {},

        allocation_count: StatInt = if (caps.stats)
            (if (is_atomic) std.atomic.Value(usize).init(0) else 0)
        else {},

        deallocation_count: StatInt = if (caps.stats)
            (if (is_atomic) std.atomic.Value(usize).init(0) else 0)
        else {},

        memory_limit: LimitInt = if (caps.hardcap)
            (if (is_atomic) std.atomic.Value(usize).init(std.math.maxInt(usize)) else std.math.maxInt(usize))
        else {},

        const Self = @This();

        /// Live tracked bytes. Returns 0 when stats are compiled out.
        pub fn currentBytes(self: *const Self) usize {
            if (comptime !caps.stats) return 0;

            return if (is_atomic) self.current_bytes.load(.monotonic) else self.current_bytes;
        }

        /// High-water mark of live bytes. Returns 0 when stats are compiled out.
        pub fn peakBytes(self: *const Self) usize {
            if (comptime !caps.stats) return 0;

            return if (is_atomic) self.peak_bytes.load(.monotonic) else self.peak_bytes;
        }

        /// Cumulative allocation count. Returns 0 when stats are compiled out.
        pub fn allocationCount(self: *const Self) usize {
            if (comptime !caps.stats) return 0;

            return if (is_atomic) self.allocation_count.load(.monotonic) else self.allocation_count;
        }

        /// Cumulative free count. Returns 0 when stats are compiled out.
        pub fn deallocationCount(self: *const Self) usize {
            if (comptime !caps.stats) return 0;

            return if (is_atomic) self.deallocation_count.load(.monotonic) else self.deallocation_count;
        }

        /// Set the hardcap ceiling at runtime. No-op when hardcap is compiled out.
        pub fn setMemoryLimit(self: *Self, limit: usize) void {
            if (comptime !caps.hardcap) return;

            if (is_atomic) {
                self.memory_limit.store(limit, .monotonic);
            } else {
                self.memory_limit = limit;
            }
        }

        /// Overwrite live bytes and lift the peak to match. For wrappers that
        /// recompute occupancy from the backing allocator (arena, fixed buffer)
        /// instead of accumulating per-alloc deltas.
        pub fn setCurrentBytes(self: *Self, current: usize) void {
            if (comptime !caps.stats) return;

            if (is_atomic) {
                self.current_bytes.store(current, .monotonic);
                self.updatePeakAtomic(current);
            } else {
                self.current_bytes = current;
                self.peak_bytes = @max(self.peak_bytes, current);
            }
        }

        /// Lower the peak high-water to the current live-byte total. After this
        /// call `peakBytes` reports the maximum live bytes observed since the
        /// reset, not since the meter was created -- the basis for a per-window
        /// peak (e.g. one benchmark sample). No-op when stats are compiled out.
        ///
        /// NOTE(atomics): the reset reads current and stores peak without a
        /// single RMW, so the caller must own the meter across the reset -- no
        /// concurrent allocation may be in flight on it at the window boundary.
        pub fn resetPeak(self: *Self) void {
            if (comptime !caps.stats) return;

            if (is_atomic) {
                self.peak_bytes.store(self.current_bytes.load(.monotonic), .monotonic);
            } else {
                self.peak_bytes = self.current_bytes;
            }
        }

        /// Bump the cumulative allocation count without touching byte totals,
        /// for wrappers that count allocations separately from byte commits.
        pub fn incrementAllocationCount(self: *Self) void {
            if (comptime !caps.stats) return;

            if (is_atomic) {
                _ = self.allocation_count.fetchAdd(1, .monotonic);
            } else {
                self.allocation_count += 1;
            }
        }

        /// Bulk-rebalance hook for arena-style wrappers whose reset() frees
        /// everything at once (ZonedFixedBuffer): frees catch up to allocs so
        /// a counter-balance leak check passes while cumulative allocation
        /// stats stay intact.
        pub fn setDeallocationCount(self: *Self, count: usize) void {
            if (comptime !caps.stats) return;

            if (is_atomic) {
                self.deallocation_count.store(count, .monotonic);
            } else {
                self.deallocation_count = count;
            }
        }

        /// Bump the cumulative free count without touching byte totals.
        pub fn incrementDeallocationCount(self: *Self) void {
            if (comptime !caps.stats) return;

            if (is_atomic) {
                _ = self.deallocation_count.fetchAdd(1, .monotonic);
            } else {
                self.deallocation_count += 1;
            }
        }

        /// Returns the post-reserve current_bytes total (exact, from the RMW),
        /// or null if the reservation would exceed the limit. The total must
        /// be fed back into commitAlloc/commitResize so the peak update uses
        /// the value this thread actually produced -- re-loading current_bytes
        /// at commit time raced with concurrent frees and lost peaks.
        pub fn tryReserve(self: *Self, len: usize) ?usize {
            if (comptime !caps.hardcap) return 0; // unused without hardcap

            const limit = if (is_atomic) self.memory_limit.load(.monotonic) else self.memory_limit;

            if (is_atomic) {
                var cur = self.current_bytes.load(.monotonic);
                while (true) {
                    if (wouldExceedLimit(cur, len, limit)) return null;
                    cur = self.current_bytes.cmpxchgWeak(cur, cur + len, .monotonic, .monotonic) orelse return cur + len;
                }
            } else {
                if (wouldExceedLimit(self.current_bytes, len, limit)) return null;
                self.current_bytes += len;
                return self.current_bytes;
            }
        }

        /// Release a `tryReserve` claim whose allocation then failed downstream,
        /// returning `current_bytes` to its pre-reserve value. No-op without
        /// hardcap. Call instead of `commitAlloc`, never in addition to it.
        pub fn rollbackReserve(self: *Self, len: usize) void {
            if (comptime !caps.hardcap) return;

            if (is_atomic) {
                _ = self.current_bytes.fetchSub(len, .monotonic);
            } else {
                self.current_bytes -= len;
            }
        }

        // NOTE(atomics): peak is updated from the RMW result this thread
        // produced (fetchAdd return or the reserved total from tryReserve),
        // never from a fresh load -- a concurrent free between the add and
        // the load permanently lost real peaks. With hardcap, a peak
        // committed while another thread's later-rolled-back reservation was
        // in flight can still include those phantom bytes; that residual
        // window is inherent to lock-free reserve/rollback and accepted for
        // a stats counter.
        /// Finalize a successful allocation previously cleared by `tryReserve`.
        /// Pass the `reserved_total` it returned so the peak reflects the value
        /// this thread produced rather than a racy re-read. Without a hardcap
        /// there was no reservation, so `len` is added here and `reserved_total`
        /// is ignored.
        pub fn commitAlloc(self: *Self, len: usize, reserved_total: usize) void {
            if (comptime !caps.stats) return;

            if (is_atomic) {
                if (comptime !caps.hardcap) {
                    const prev = self.current_bytes.fetchAdd(len, .monotonic);
                    self.updatePeakAtomic(prev + len);
                } else {
                    self.updatePeakAtomic(reserved_total);
                }
                _ = self.allocation_count.fetchAdd(1, .monotonic);
            } else {
                if (comptime !caps.hardcap) {
                    self.current_bytes += len;
                }

                self.peak_bytes = @max(self.peak_bytes, self.current_bytes);
                self.allocation_count += 1;
            }
        }

        /// Finalize a free: subtract `len` from live bytes and bump the free
        /// count. Counters drop the same `len` the matching alloc committed.
        pub fn commitFree(self: *Self, len: usize) void {
            if (comptime !caps.stats) return;

            if (is_atomic) {
                _ = self.current_bytes.fetchSub(len, .monotonic);
                _ = self.deallocation_count.fetchAdd(1, .monotonic);
            } else {
                self.current_bytes -= len;
                self.deallocation_count += 1;
            }
        }

        /// Finalize an in-place resize. Adjusts live bytes by the signed delta
        /// between `old_len` and `new_len`; on growth under a hardcap, pass the
        /// `reserved_total` from a prior `tryReserve(new_len - old_len)` so the
        /// peak uses this thread's value. Does not change the allocation count.
        pub fn commitResize(self: *Self, old_len: usize, new_len: usize, reserved_total: usize) void {
            if (comptime !caps.stats) return;

            if (new_len > old_len) {
                const delta = new_len - old_len;

                if (is_atomic) {
                    if (comptime !caps.hardcap) {
                        const prev = self.current_bytes.fetchAdd(delta, .monotonic);
                        self.updatePeakAtomic(prev + delta);
                    } else {
                        self.updatePeakAtomic(reserved_total);
                    }
                } else {
                    if (comptime !caps.hardcap) {
                        self.current_bytes += delta;
                    }

                    self.peak_bytes = @max(self.peak_bytes, self.current_bytes);
                }
            } else if (old_len > new_len) {
                const delta = old_len - new_len;

                if (is_atomic) {
                    _ = self.current_bytes.fetchSub(delta, .monotonic);
                } else {
                    self.current_bytes -= delta;
                }
            }
        }

        fn updatePeakAtomic(self: *Self, current: usize) void {
            var peak = self.peak_bytes.load(.monotonic);

            while (current > peak) {
                peak = self.peak_bytes.cmpxchgWeak(peak, current, .monotonic, .monotonic) orelse break;
            }
        }

        // Overflow-safe: `current + delta` could wrap past `limit` and falsely
        // pass, so the check is rearranged into subtraction. `delta > limit`
        // catches the single allocation that is already too big on its own;
        // `current > limit - delta` is then evaluated with `limit - delta`
        // known non-negative.
        fn wouldExceedLimit(current: usize, delta: usize, limit: usize) bool {
            return delta > limit or current > limit - delta;
        }
    };
}

test "hardcap reservation treats usize overflow as over limit" {
    const Limited = Meter(.{
        .stats = true,
        .hardcap = true,
        .frames = false,
        .lifecycle = false,
        .runtime_export = false,
    }, false);
    var meter: Limited = .{};
    meter.setMemoryLimit(std.math.maxInt(usize));
    try std.testing.expect(meter.tryReserve(std.math.maxInt(usize)) != null);
    try std.testing.expect(meter.tryReserve(1) == null);
}

test "resetPeak lowers the high-water to current live bytes" {
    const Metered = Meter(.{
        .stats = true,
        .hardcap = false,
        .frames = false,
        .lifecycle = false,
        .runtime_export = false,
    }, false);
    var meter: Metered = .{};
    meter.commitAlloc(1000, 1000); // current=1000, peak=1000
    meter.commitFree(400); // current=600, peak still 1000
    try std.testing.expectEqual(@as(usize, 1000), meter.peakBytes());

    meter.resetPeak(); // peak := current
    try std.testing.expectEqual(@as(usize, 600), meter.peakBytes());
    try std.testing.expectEqual(@as(usize, 600), meter.currentBytes());
}

test "disabled meter is zero-sized and reports zero" {
    const Disabled = Meter(.{
        .stats = false,
        .hardcap = false,
        .frames = false,
        .lifecycle = false,
        .runtime_export = false,
    }, false);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Disabled));

    var meter: Disabled = .{};
    try std.testing.expect(meter.tryReserve(1024) != null);
    meter.commitAlloc(1024, 1024);
    try std.testing.expectEqual(@as(usize, 0), meter.currentBytes());
    try std.testing.expectEqual(@as(usize, 0), meter.peakBytes());
    try std.testing.expectEqual(@as(usize, 0), meter.allocationCount());
    try std.testing.expectEqual(@as(usize, 0), meter.deallocationCount());
}
