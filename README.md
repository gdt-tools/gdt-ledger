<h1 align="center">gdt-ledger - Game Developer's Toolkit for Memory Accounting</h1>

<p align="center"><b><i>Name it. Cap it. Catch it lying.</i></b></p>

<p align="center">
  <a href="#-quick-flex"><img src="https://img.shields.io/badge/Zig-0.16-F7A41D?style=for-the-badge&logo=zig&logoColor=white" alt="Zig 0.16"></a>
  <a href="#-install--versioning"><img src="https://img.shields.io/badge/version-0.2606.0-F7A41D?style=for-the-badge" alt="version 0.2606.0"></a>
  <a href="#-what-you-get"><img src="https://img.shields.io/badge/dependencies-0-brightgreen?style=for-the-badge" alt="zero dependencies"></a>
  <a href="LICENSE-MIT"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-F7A41D?style=for-the-badge" alt="license MIT OR Apache-2.0"></a>
</p>

---

You allocated 8 gigs. You can name maybe four of them; the rest is "engine stuff." You picked a memory budget so the game fits the machines you promised it would - and the game still blew past it, with nothing on screen telling you which subsystem to blame.

`gdt-ledger` puts a ceiling on every subsystem that *actually stops the bleed*, plus a running balance, a soft budget, and a one-call dump of the whole tree. Now "which subsystem to blame" is a question with an answer. That's your dev build.

Ship it `.off` and it **vanishes at comptime** - the alloc path is the bare allocator you handed it, like the lib was never there. You were about to ask what it costs in a build that turns it off. Nothing. Next question.

> **`gdt-ledger` is not an allocator.** It's a budget tree that *wraps* the allocators you already have - you bring the memory, it keeps the books.

---

## 🚀 **Quick Flex**

```zig
const std = @import("std");
const ledger = @import("gdt_ledger");

// Policy lives in your root.
pub const gdt_ledger_options = .{ .default_mode = .full };
pub var gdt_ledger_runtime: ledger.RootRuntime = .{};

const Physics = ledger.Zone(.{
    .name = "physics",
    .budget = 64 * 1024 * 1024,   // soft: a gauge you read
    .hardcap = 256 * 1024 * 1024, // hard: this zone's alloc FAILS, no one else's
    .frame_tracking = true,
});

pub fn main() !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    const gpa = dbg.allocator();

    var physics = try Physics.init(.{
        .backing_allocator = gpa, // where the user's bytes go
        .control_allocator = gpa, // where ledger keeps its own books
    });
    defer std.debug.assert(physics.deinit() == .ok); // .ok / .leak / .live_children

    const ally = physics.allocator();
    const sim = try ally.alloc(u8, 2 * 1024 * 1024);
    defer ally.free(sim);

    physics.markFrame();

    std.debug.print("used={} peak={} allocs={} budget={d:.1}% hardcap={d:.1}%\n", .{
        physics.currentBytes(),
        physics.peakBytes(),
        physics.allocationCount(),
        physics.budgetPercent(),
        physics.hardcapPercent(),
    });
}
```

Output:

```shell
$ zig build run-readme
used=2097152 peak=2097152 allocs=1 budget=3.1% hardcap=0.8%
```

And the dump is not decorative. `examples/engine.zig` wires a fuller tree - `io` plus an
`engine` > `physics` / `render` / `ai` subsystem tree - and asks where the bytes went after one
frame:

```text
=== Zone tree after one frame ===

Zone          used    peak  allocs  frees  budget            hardcap
io              0B      0B       0      0    4.0KiB (0.0%)
engine      3.8KiB  3.8KiB       3      0  256.0KiB (1.5%)  512.0KiB (0.7%)
  physics   1.0KiB  1.0KiB       1      0   64.0KiB (1.6%)
  render    2.0KiB  2.0KiB       1      0  128.0KiB (1.6%)
  ai          830B    830B       1      0   32.0KiB (2.5%)
    scratch   830B    830B       1      0    8.0KiB (10.1%)
```

That whole tree lives behind one root knob.

More demos to run on your hardware - each prints what *your* build actually accounted for:

| Example                     | What it shows                                                                                    |
| --------------------------- | ------------------------------------------------------------------------------------------------ |
| `zig build run-basic`       | One zone: balance, peak, allocs, budget percent                                                  |
| `zig build run-subzones`    | A parent/child tree and how a child's bytes roll up into its ancestors                           |
| `zig build run-build-modes` | The same code under `.off` / `.guardrails` / `.full` via `-Dledger-mode=`                        |
| `zig build run-wrappers`    | Arena / pool / fixed-buffer / debug allocators, metered                                          |
| `zig build run-engine`      | A miniature engine, dumped as text and JSON                                                      |
| `zig build run-leak-hunt`   | `ZonedDebug` pairing: one `deinit()` returns the zone's leak status + the DebugAllocator's trace |

---

## ✨ **What You Get**

* **Hierarchical zones** - `engine > render > shadows`, each with its own balance sheet. The tree *is* the readout.
* **Hardcaps that bite** - a budget is a polite cough; a hardcap returns `error.OutOfMemory` to the overspender and nobody else. Blast radius: a subsystem, not the game.
* **Zero-cost when off** - `.off` compiles the instrumentation to nothing. Provable via `@typeInfo`, not promised in a footnote.
* **Text + JSON dumps** - the same readout as human-readable text or machine-parseable JSON, your pick.
* **Leak & lifecycle forensics** - `deinit()` returns `.ok` / `.leak` / `.live_children`; a leak arrives with the zone's name attached.
* **Per-frame deltas** - `markFrame()` answers "who allocated 40 MB on frame 12,043," not "the heap grew."
* **The app owns the policy** - diagnostics live in *your* root; silence any subtree from the top with one rule.
* **Allocator wrappers** - arena, pool, fixed-buffer, debug; the weird allocators get a line in the books too.
* **Zero dependencies you'll regret** - Zero. `.dependencies = .{}`.

---

## 🏎️ **How It Works**

### Three modes, one knob

`gdt-ledger` isn't a global counter you `#ifdef` in and out by hand. The mode is comptime policy: the
zone *type* changes shape, and the disabled half doesn't exist in the binary.

| Mode              | What gets compiled in                                                         | What it costs                                 |
| ----------------- | ----------------------------------------------------------------------------- | --------------------------------------------- |
| **`.full`**       | counters, hardcaps, frame deltas, lifecycle, auto-linked runtime, dump/export | a few atomics + a handful of words per zone   |
| **`.guardrails`** | counters, hardcaps, lifecycle (live-children / leak detection)                | same, minus frame stats and export wiring     |
| **`.off`**        | nothing - the base zone passes the backing allocator straight through         | `@sizeOf(State) == 0`, zero branches on alloc |

Modes cascade down the zone-nesting hierarchy: a subzone's effective mode is `min(parent, child)`
(`off < guardrails < full`). How you *assign* a mode per subsystem is the next part.

### Driving it

`gdt-ledger` is instrumentation, so the *application root* owns the policy. Declare it once in your root
source; with no declaration at all, every zone is `.off` and compiled away.

```zig
pub const gdt_ledger_options = .{
    .default_mode = .guardrails,                          // every app zone gets leak + hardcap safety
    .rules = .{
        .{ .scope = "gdt_vulkan", .mode = .full },        // full readout on the subsystem you're profiling
        .{ .scope = "gdt_vulkan/cache", .mode = .off },   // ...but mute its noisy cache subtree
    },
};
pub var gdt_ledger_runtime: ledger.RootRuntime = .{};     // storage any .full zone links into
```

Zones opt into a scope explicitly, and the longest matching rule wins. A rule pointed at a scope that
doesn't exist fails the build instead of silently doing nothing.

#### Rules select, subzones clamp

Two different knobs decide a zone's mode, and confusing them catches everyone:

* **A rule selects the mode for a scope path** - longest-prefix wins, and it can dim *or* brighten.
  `gdt_vulkan = .off` plus `gdt_vulkan/upload = .full` spotlights `upload` while the rest of the
  subsystem stays dark.
* **A subzone clamps to its parent** - `min(parent, child)`. A real subzone (`subzone` / `initUnder`)
  allocates *through* its parent, so it physically cannot track more than the parent does.

```zig
// rules: gdt_vulkan = .off, gdt_vulkan/upload = .full, gdt_vulkan/cache/detail = .full
const Vulkan = ledger.scope("gdt_vulkan");

const Upload      = Vulkan.Zone(.{ .name = "upload" });   // ROOT zone -> .full (rule brightens it past gdt_vulkan=.off)
const Cache       = Vulkan.Zone(.{ .name = "cache" });    // ROOT zone -> .off  (inherits gdt_vulkan=.off)
const CacheDetail = Cache.subzone(.{ .name = "detail" }); // SUBZONE   -> .off  (own .full rule, clamped by .off parent)
```

Rule of thumb: **rules route by name, subzones contain by allocation.** Want a guaranteed budget fence?
Nest it - subzones clamp. Want a diagnostic spotlight in an otherwise-dark subsystem? Put a rule on a
root zone - rules select.

**Off-the-books subzones** are the sharp edge: an explicitly-`.off` child under a live parent allocates
straight from the **root backing allocator**, invisible to every ancestor's stats *and hardcaps*. If you
want a real budget fence around a subtree, don't punch holes in it.

### Wrappers

A plain zone wraps anything that speaks the allocator vtable. Some allocators don't - their semantics
(retained pages, fixed buffers, pool slots) don't fit a generic `alloc`/`free`. Those get a purpose-built
wrapper that meters the thing that actually matters for that allocator:

| You have...                     | Wrap it with...    | It meters...                                        |
| ------------------------------- | ------------------ | --------------------------------------------------- |
| a normal allocator              | `ledger.Zone`      | every `alloc` / `free` through it                   |
| `std.heap.ArenaAllocator`       | `ZonedArena`       | retained arena chunk traffic (not per-object)       |
| `std.heap.MemoryPool(T)`        | `ZonedPool`        | the pool's retained backing storage                 |
| `std.heap.FixedBufferAllocator` | `ZonedFixedBuffer` | retained footprint vs the fixed buffer (root only)  |
| `std.heap.DebugAllocator`       | `ZonedDebug`       | zone books + the debug allocator's own leak verdict |

All wrappers keep their allocator-facing state in heap-stable storage, so the public handle can move
freely after init.

---

## 🚫 **The Fine Print**

### Misuse is a compile error

The dirty secret of diagnostics libraries: half of them let you misconfigure them into silence and never
tell you. `gdt-ledger` would rather fail your build than lie to your dashboard.

* Unknown option field? Compile error.
* Unknown rule field, or two rules fighting over one scope? Compile error.
* A scoped rule that matches *nothing* - the classic "I renamed the zone, the rule is now dead weight"?
  Declare your known scopes and `validateRules` names the offender at comptime:

```zig
test "ledger rules are live" {
    comptime ledger.validateRules(gdt_ledger_options, &.{
        "gdt_vulkan/upload",
        "gdt_vulkan/cache",
        "gdt_vulkan/cache/detail", // subzone paths are targets too
    });
}
```

`zig build check` runs the whole negative-compile suite: a dozen ways to hold this wrong, each one a build
failure with the reason named, none of them a runtime surprise.

### Things it doesn't pretend

The jokes stop here, because these are the trades that bite if you assume otherwise.

* **It does not make your allocator thread-safe.** `thread_safe` makes a zone's *counters and hardcap
  reservation* atomic - nothing more. Wrapper-owned state (`ZonedArena` / `ZonedPool` / `ZonedFixedBuffer`
  are single-threaded, like the std types they wrap), concurrent `markFrame()`, and zone *lifecycle*
  (creating a child while another thread deinits the parent) are still yours to serialize.
* **It does not make an arena per-allocation honest.** `ZonedArena` meters arena *chunk* traffic, not your
  `alloc` calls - the zone sits below the arena. You're watching retained backing pages, which is the
  right number for an arena and the wrong one if you expected per-object accounting.
* **`.off` does not detect lifecycle bugs.** Double-deinit and use-after-deinit are *detected* only when
  instrumentation is on. That's the zero-cost contract working: run dev builds `.full` or `.guardrails`
  and the bugs surface there, not in the shipping binary that compiled the checks away.
* **Dumps are reporting-grade, not transactional.** `snapshot()` reads each field monotonically, so a row
  can be internally skewed under live mutation (a count without its bytes yet). It's a readout for a HUD
  or a log, not a consistent point-in-time memory transaction.
* **The auditor stays off the books it audits.** Its bookkeeping lives in a separate `control_allocator`,
  so it never shows up in the `backing_allocator` it's measuring.

---

## 🤔 **`gdt-ledger` vs One Global Allocator and Vibes**

What `gdt-ledger` is really up against isn't another library - it's the status quo: one allocator for
everything and a prayer. The before/after:

| When a subsystem misbehaves...   | Global allocator + vibes                        | `gdt-ledger`                                                                      |
| -------------------------------- | ----------------------------------------------- | --------------------------------------------------------------------------------- |
| ...and runs away on memory       | the *process* OOMs, somewhere, eventually       | the texture cache hits its 512 MiB cap, evicts, keeps going - nobody else notices |
| ...and leaks across a level load | "the heap is bigger than yesterday"             | `.leak` at deinit - it names the zone that did it                                 |
| ...in your shipping build        | you stripped the diagnostics by hand, hopefully | `.off` - it was never in the binary                                               |

> "But I already have a debug allocator." Good - keep it. It does the per-allocation autopsy; `gdt-ledger`
> does the per-subsystem books. They're not rivals: `ZonedDebug` hands you both verdicts in one call. 🤝

Here's that one call (`zig build run-leak-hunt`) - a physics zone leaks a frame buffer across a level
load, and a single `deinit()` returns both verdicts on stdout:

```text
leak hunt -- one deinit(), two verdicts:
  ledger  zone=physics  status=leak  4.0KiB over 1 live alloc
  debug   status=leak
```

The `debug` verdict and the trace come from the stdlib `DebugAllocator` that `ZonedDebug` wraps - it
drops the autopsy on stderr, pointing at the exact alloc:

```text
error(DebugAllocator): memory address 0x7fdc19d00000 leaked:
  examples/leak_hunt.zig:42:45: 0x11d42a6 in main (leak_hunt.zig)
    const frame = try hunt.allocator().alloc(u8, 4096);
                                            ^
```

---

## 📦 **Install & Versioning**

### Add it

Fetch it and pin the release into your `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/gdt-tools/gdt-ledger#v0.2606.0
```

Then wire the module in `build.zig`:

```zig
const ledger = b.dependency("gdt_ledger", .{});
exe.root_module.addImport("gdt_ledger", ledger.module("gdt_ledger"));
```

Then put the policy in your root and go. (Or vendor the source like it's still the 90s. We don't judge.)

### CalVer, deal with it

> Wait, CalVer for a lib? Ya Idjits or something? (Bobby Singer voice, obviously.)

Yep, we timestamp our releases instead of counting semantic digits. Why? Because Zig pins dependencies by
**hash**, not by a version range, so the number isn't feeding a resolver - it's feeding *you*. And a date
is the most honest thing a human can read off a release.

| CalVer Perk            | Why You Care                                                                                                   |
| ---------------------- | -------------------------------------------------------------------------------------------------------------- |
| Instant age check      | `0.2606.0` -> June 2026. No tag archaeology to find out if a lib is fresh off the compiler or a fossil.        |
| Honesty about breakage | New month, possibly new shape. You'll know from the number, and the CHANGELOG shows the fix. We're not shy.    |
| No bike-shedding       | No `minor`-vs-`patch` debate to stall a release. The time goes into code improvements, not the version string. |

Each year/month is an API epoch (`0.YYMM.patch`). If we break you, the notes show the fix; if we don't,
the bump is painless. And if we mess up, the date tells you exactly when to roast us in Issues. 😎

---

## 🧩 **Part of the GDT Ecosystem**

`gdt-ledger` is one library in the Game Developer's Toolkit - a family of standalone Zig and Rust libraries
built from years in top-tier studios. Each stands on its own and ships from its own repo. Browse the rest
at [gdt-tools](https://github.com/gdt-tools); this one has no dependencies at all.

---

## 🤝 **How Can I Contribute?**

Find something that's missing, broken, or accounting for fewer bytes than your standards require.

Open an issue. Bonus points if you make a PR. A 🍪 if the dump path gets cheaper.

But wait, where is the **CODE_OF_CONDUCT**?

**Code of what?** Quoting a famous internet meme:

> "Apologies for the very personal question, but were you homeschooled by a pigeon?"

We're all civilised here. Just don't be an asshole and we're good. 🤞🏻

And hey, mad props to the entire Zig community. Y'all make low-level coding sexy again. This stuff is built
with love, for the love of the game (and allocators that finally tell the truth).

---

## ⚖️ **License**

MIT OR Apache-2.0 - because we believe in *freedom of choice* (and legally covering our butts).

---

<p align="center">Made with ❤️ by <a href="https://wildpixelgames.com">Wild Pixel Games</a> - We read receipts.</p>
<p align="center"><i>"My RAM used to vanish into a black hole labeled 'engine.' Now I can name all 8 gigs - and the one that's lying."</i> - A developer who reconciles the books</p>
