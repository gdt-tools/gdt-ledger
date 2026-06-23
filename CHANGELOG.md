# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow CalVer (`0.YYMM.patch`): each year/month is an API epoch, so a
new month may bring a new shape. The notes here show what moved and how to
adjust.

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
