# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow CalVer (`0.YYMM.patch`): each year/month is an API epoch, so a
new month may bring a new shape. The notes here show what moved and how to
adjust.

## [0.2607.0] - 2026-07-04

Additions for per-window allocation accounting (a benchmark harness handing a
tracked allocator to a measured body). Purely additive; no existing behavior
changes.

### 🚀 Added

- `resetPeak()` on the meter and `TrackedAllocator.State`: lower the peak
  high-water to the current live-byte total, so `peakBytes` reports the maximum
  live bytes observed since the reset rather than since creation - a per-window
  peak (e.g. one benchmark sample). No-op when stats are compiled out. It is a
  single-owner window boundary: the caller must have no concurrent allocation in
  flight on the meter across the reset (the peak is lowered without an atomic
  read-modify-write).
- `TrackedAllocator` re-exported from the public root. The metering allocator
  adapter can now be instantiated directly (`ledger.TrackedAllocator(config)`)
  for callers that want the `State`/`Promoted` accounting without a named zone.

### 📦 Compatibility

- Requires Zig 0.16.0 or newer. Zero dependencies.

## [0.2606.0] - 2026-06-23

Initial public release.

### 🚀 Features

- Named memory zones over any backing allocator, tracking live bytes, peak, and
  alloc/free counts with no per-allocation metadata.
- Three modes (`.full`, `.guardrails`, `.off`) selected by app-owned policy
  (`gdt_ledger_options` + `gdt_ledger_runtime`). `.off` is void-eliminated to
  zero bytes and compiles down to the bare backing allocator.
- Per-zone hardcap (a hard ceiling that fails the overspender's allocation,
  with overflow-safe checks) and budget (a soft gauge that may read past 100%).
- Hierarchical subzones: a child's allocations chain through and count into its
  parent, and the child's effective mode is clamped to the parent's
  (`min(parent, child)`).
- Scope rules resolve a zone's mode by longest-prefix match, so an application
  can dim or brighten a dependency's zones without touching its code.
- Per-frame allocation deltas via `markFrame` (`.full` only).
- Specialized wrappers that meter what a plain zone would misrepresent:
  `ZonedArena` (retained arena pages), `ZonedPool` (pool backing storage),
  `ZonedFixedBuffer` (fixed-buffer footprint), and `ZonedDebug` (the zone
  verdict plus the embedded `std.heap.DebugAllocator`'s leak check, both from
  one `deinit`).
- Runtime registry with text and JSON dumps (`dumpToWriter`, `dumpToJson`,
  `snapshot`, `zoneCount`) over the live `.full` zones.
- Comptime validation: unknown option or rule fields, duplicate scopes, dead
  rules, and misuse (subzone `init`, fixed-buffer subzones, and the like) are
  build errors, not runtime surprises.

### 📅 Versioning

- CalVer `0.YYMM.patch`. Zig pins dependencies by hash, not by range, so the
  number is for humans: `0.2606.0` reads as June 2026.

### 📦 Compatibility

- Requires Zig 0.16.0 or newer. Zero dependencies.
