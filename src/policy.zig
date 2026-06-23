//! Mode policy: how a zone's effective `LedgerMode` is decided.
//!
//! Policy lives in the application root (`gdt_ledger_options`), read here
//! structurally via `@import("root")`. This file owns the two resolution
//! mechanisms and their comptime validation; it holds no zone state.
//!
//! - `resolveMode` selects a scoped zone's mode by longest-prefix rule match;
//! - `clampMode` (with `modeRank`) caps a subzone at its parent's mode.
//!
//! `validateOptions` allowlists every options field, and `validateRules` lets
//! an app prove no rule is dead. Unknown fields, malformed rules, and duplicate
//! scopes are `@compileError`s rather than runtime surprises.

const std = @import("std");

const root = @import("root");
const validation = @import("validation.zig");

/// Instrumentation level a zone runs at, lowest to highest: `.off` (no
/// accounting, state void-eliminated to zero bytes), `.guardrails` (counters
/// and hardcaps, no runtime export or frame stats), `.full` (everything).
pub const LedgerMode = enum {
    full,
    guardrails,
    off,
};

/// Effective default mode for unscoped zones, resolved once at comptime from
/// `root.gdt_ledger_options.default_mode`. `.off` when root declares no options.
pub const default_mode: LedgerMode = defaultMode();

/// Total order on modes for cascade comparison: off=0 < guardrails=1 < full=2.
pub fn modeRank(comptime mode: LedgerMode) u8 {
    return switch (mode) {
        .off => 0,
        .guardrails => 1,
        .full => 2,
    };
}

/// Cap a subzone's mode at its parent's: returns `child` when it is no more
/// enabled than `parent`, otherwise `parent`.
///
/// This is the subzone cascade, distinct from rule resolution. A child zone's
/// allocations chain through its parent, so a child cannot be more instrumented
/// than the parent backing it: `effective = min(parent, child)`, and disabling
/// a parent disables its whole subtree. Scope *rules* do not pass through here:
/// a deeper rule can still raise a zone's mode by longest-prefix match (see
/// `resolveMode`). Only the allocation-chain (subzone) relationship clamps.
pub fn clampMode(comptime parent: LedgerMode, comptime child: LedgerMode) LedgerMode {
    return if (modeRank(child) <= modeRank(parent)) child else parent;
}

fn defaultMode() LedgerMode {
    if (!@hasDecl(root, "gdt_ledger_options")) return .off;

    validateOptions();

    const Options = @TypeOf(root.gdt_ledger_options);
    if (!@hasField(Options, "default_mode")) return .off;

    return parseMode(root.gdt_ledger_options.default_mode);
}

/// Resolve a scoped zone's mode by longest-prefix rule match.
///
/// Unscoped zones (`is_scoped == false`) get `default_mode`. For scoped zones,
/// every rule in `root.gdt_ledger_options.rules` whose `.scope` is a path-prefix
/// of `policy_path` competes; the longest matching scope wins, falling back to
/// `default_mode` when none match. A more-specific rule may raise OR lower the
/// mode -- there is no clamping here (clamping is the subzone cascade,
/// `clampMode`). All work is comptime.
///
/// Emits a `@compileError` when `policy_path` is malformed or a rule entry is
/// missing `.scope`/`.mode`.
pub fn resolveMode(comptime policy_path: []const u8, comptime is_scoped: bool) LedgerMode {
    if (!is_scoped) return default_mode;

    if (!@hasDecl(root, "gdt_ledger_options")) return default_mode;

    validateOptions();

    const Options = @TypeOf(root.gdt_ledger_options);
    if (!@hasField(Options, "rules")) return default_mode;

    validation.validatePolicyPath(policy_path, "zone policy path");

    var best_mode = default_mode;
    var best_len: usize = 0;

    inline for (root.gdt_ledger_options.rules) |rule| {
        const Rule = @TypeOf(rule);

        if (!@hasField(Rule, "scope")) {
            @compileError("gdt-ledger: gdt_ledger_options.rules entries must define .scope");
        }

        if (!@hasField(Rule, "mode")) {
            @compileError("gdt-ledger: gdt_ledger_options.rules entries must define .mode");
        }

        validation.validatePolicyPath(rule.scope, "rule scope");

        if (validation.matchesRule(rule.scope, policy_path) and rule.scope.len >= best_len) {
            best_mode = parseMode(rule.mode);
            best_len = rule.scope.len;
        }
    }

    return best_mode;
}

// NOTE(multi-instance): options access is structural (`@hasField`) because
// multiple gdt_ledger module instances must agree on one root policy without
// nominal type equality. Structural reading is typo-silent by default, so
// every field must pass this explicit allowlist -- a misspelled
// `default_mode` silently disabling the entire ledger is the worst failure
// mode an opt-in instrumentation lib can have.
fn validateOptions() void {
    const Options = @TypeOf(root.gdt_ledger_options);
    if (@typeInfo(Options) != .@"struct") {
        @compileError("gdt-ledger: gdt_ledger_options must be a struct literal");
    }

    inline for (@typeInfo(Options).@"struct".fields) |field| {
        if (!nameIn(field.name, &.{ "default_mode", "rules" })) {
            @compileError("gdt-ledger: unknown gdt_ledger_options field '" ++ field.name ++ "'; valid fields: default_mode, rules");
        }
    }

    if (!@hasField(Options, "rules")) return;

    const Rules = @TypeOf(root.gdt_ledger_options.rules);
    if (@typeInfo(Rules) != .@"struct" or !@typeInfo(Rules).@"struct".is_tuple) {
        @compileError("gdt-ledger: gdt_ledger_options.rules must be a tuple of rule literals");
    }

    inline for (root.gdt_ledger_options.rules, 0..) |rule, i| {
        const Rule = @TypeOf(rule);
        if (@typeInfo(Rule) != .@"struct") {
            @compileError("gdt-ledger: gdt_ledger_options.rules entries must be struct literals");
        }

        inline for (@typeInfo(Rule).@"struct".fields) |field| {
            if (!nameIn(field.name, &.{ "scope", "mode" })) {
                @compileError("gdt-ledger: unknown gdt_ledger_options rule field '" ++ field.name ++ "'; valid fields: scope, mode");
            }
        }

        if (!@hasField(Rule, "scope")) {
            @compileError("gdt-ledger: gdt_ledger_options.rules entries must define .scope");
        }

        if (!@hasField(Rule, "mode")) {
            @compileError("gdt-ledger: gdt_ledger_options.rules entries must define .mode");
        }

        inline for (root.gdt_ledger_options.rules, 0..) |other, j| {
            if (j > i and std.mem.eql(u8, rule.scope, other.scope)) {
                @compileError("gdt-ledger: duplicate rule scope '" ++ rule.scope ++ "' in gdt_ledger_options.rules");
            }
        }
    }
}

/// Prove at comptime that no scope rule is dead.
///
/// Call from an app test with the full list of scoped zone paths the app
/// actually declares. Any rule in `options.rules` whose `.scope` matches none
/// of `known_scopes` is a `@compileError`.
///
/// Matching is strict and one-directional: `known_scopes` must enumerate every
/// path a rule targets, INCLUDING subzone paths. A rule for "a/b/c" is not
/// satisfied by knowing "a/b" -- accepting ancestor prefixes would let rules for
/// never-declared subzones pass silently. Dead-rule detection cannot be
/// automatic: scoped paths are an open world (any dependency may declare one)
/// and `.off` rules suppress the runtime linking that would otherwise expose
/// them. Rules left inert by the mode cascade still count as live; clamping is
/// policy, not a typo.
pub fn validateRules(comptime options: anytype, comptime known_scopes: []const []const u8) void {
    comptime {
        const Options = @TypeOf(options);
        if (@typeInfo(Options) != .@"struct") {
            @compileError("gdt-ledger: validateRules expects a gdt_ledger_options-style struct literal");
        }

        if (!@hasField(Options, "rules")) return;

        for (options.rules) |rule| {
            const Rule = @TypeOf(rule);
            if (!@hasField(Rule, "scope")) {
                @compileError("gdt-ledger: gdt_ledger_options.rules entries must define .scope");
            }

            var matched = false;
            for (known_scopes) |path| {
                if (validation.matchesRule(rule.scope, path)) {
                    matched = true;
                    break;
                }
            }

            if (!matched) {
                @compileError("gdt-ledger: dead rule: scope '" ++ rule.scope ++ "' matches no known scoped zone path (known_scopes must list every rule-targeted path, including subzone paths)");
            }
        }
    }
}

test "validateRules accepts live rules" {
    comptime validateRules(.{
        .default_mode = .guardrails,
        .rules = .{
            .{ .scope = "gdt_vulkan", .mode = .off },
            .{ .scope = "gdt_vulkan/upload", .mode = .full },
        },
    }, &.{ "gdt_vulkan/upload", "gdt_vulkan/cache" });
}

test "validateRules accepts options without rules" {
    comptime validateRules(.{ .default_mode = .full }, &.{"gdt_vulkan"});
}

fn nameIn(comptime name: []const u8, comptime list: []const []const u8) bool {
    for (list) |allowed| {
        if (std.mem.eql(u8, name, allowed)) return true;
    }
    return false;
}

fn parseMode(comptime mode: anytype) LedgerMode {
    const tag = @tagName(mode);

    inline for (@typeInfo(LedgerMode).@"enum".fields) |field| {
        if (std.mem.eql(u8, tag, field.name)) return @field(LedgerMode, field.name);
    }

    @compileError("gdt-ledger: unsupported ledger mode '" ++ tag ++ "'");
}
