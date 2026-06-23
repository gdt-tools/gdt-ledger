//! Comptime validation for zone names and scope paths.
//!
//! Shared by the zone factory and the policy resolver. Names must be JSON-safe
//! so `dumpToJson` can write them unescaped, and scope paths use '/' as the only
//! segment separator. Every check runs at comptime and rejects with
//! `@compileError`; there is no runtime validation path.

const std = @import("std");

/// Validate a single scope-name segment: non-empty, JSON-safe, and containing
/// no '/' (a scope name is one path segment, not a joined path). `@compileError`
/// on violation.
pub fn validateScopeName(comptime scope_name: []const u8) void {
    if (scope_name.len == 0) {
        @compileError("gdt-ledger: scope name must not be empty");
    }

    for (scope_name) |c| {
        if (c == '/') {
            @compileError("gdt-ledger: scope name must be a single path segment; '/' is reserved for zone paths");
        }
    }

    validateName(scope_name, "scope name");
}

/// Validate one segment of a joined zone path: JSON-safe and containing no '/'.
/// `what` names the segment in the error message. `@compileError` on violation.
pub fn validatePathSegment(comptime name: []const u8, comptime what: []const u8) void {
    validateName(name, what);

    for (name) |c| {
        if (c == '/') {
            @compileError("gdt-ledger: " ++ what ++ " must be a single path segment; '/' is reserved for joined zone paths");
        }
    }
}

/// Segment-aware prefix match, not a naive `startsWith`.
///
/// True iff `rule_scope` equals `policy_path` or is a '/'-bounded prefix of it,
/// so "a/b" matches "a/b" and "a/b/c" but not "a/bc". Direction is strict: a
/// rule deeper than the path never matches.
pub fn matchesRule(comptime rule_scope: []const u8, comptime policy_path: []const u8) bool {
    if (std.mem.eql(u8, rule_scope, policy_path)) return true;

    if (!std.mem.startsWith(u8, policy_path, rule_scope)) return false;

    return policy_path.len > rule_scope.len and policy_path[rule_scope.len] == '/';
}

/// Validate a full scope path: non-empty, no leading/trailing '/', no empty
/// segments, and JSON-safe. `what` names the path in the error message.
/// `@compileError` on violation.
pub fn validatePolicyPath(comptime path: []const u8, comptime what: []const u8) void {
    if (path.len == 0) {
        @compileError("gdt-ledger: " ++ what ++ " must not be empty");
    }

    if (path[0] == '/' or path[path.len - 1] == '/') {
        @compileError("gdt-ledger: " ++ what ++ " must not start or end with '/'");
    }

    for (path, 0..) |c, i| {
        if (c == '/' and i > 0 and path[i - 1] == '/') {
            @compileError("gdt-ledger: " ++ what ++ " must not contain empty path segments");
        }
    }

    validateName(path, what);
}

/// JSON-safety core shared by the other validators: rejects empty values and
/// any character that would need escaping in `dumpToJson` output -- '"', '\\',
/// or a control character (< 0x20). `@compileError` on violation.
pub fn validateName(comptime value: []const u8, comptime what: []const u8) void {
    if (value.len == 0) {
        @compileError("gdt-ledger: " ++ what ++ " must not be empty");
    }

    for (value) |c| {
        if (c == '"' or c == '\\' or c < 0x20) {
            @compileError("gdt-ledger: " ++ what ++ " contains characters unsafe for JSON output (\\\\, \\\", or control chars)");
        }
    }
}

/// Return `value` with a trailing NUL, as a sentinel-terminated slice for the
/// C-style zone-name pointer the runtime registry stores.
pub fn sentinelName(comptime value: []const u8) [:0]const u8 {
    return value ++ "\x00";
}

test "matchesRule is segment-aware, not naive startsWith" {
    comptime {
        const assert = @import("std").debug.assert;
        // Exact match and segment-boundary prefix match.
        assert(matchesRule("engine", "engine"));
        assert(matchesRule("engine", "engine/render"));
        assert(matchesRule("engine/render", "engine/render/shadows"));
        // A prefix that does not end at a '/' boundary must NOT match.
        assert(!matchesRule("eng", "engine"));
        assert(!matchesRule("engine/rend", "engine/render"));
        assert(!matchesRule("gdt_vul", "gdt_vulkan/upload"));
        // Rule deeper than the path never matches (strict direction).
        assert(!matchesRule("engine/render", "engine"));
    }
}
