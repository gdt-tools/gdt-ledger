const std = @import("std");

// Keep tag-compatible with src/policy.zig:LedgerMode. Source policy parsing is
// structural by tag name so build option values do not introduce nominal type
// coupling.
const LedgerMode = enum {
    full,
    guardrails,
    off,
};

fn createLedgerModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}

// NOTE(build): two traps conspired to make the old mode matrix vacuous:
// (1) test collection only walks the tested module's FILE-import graph -- a
// `test { _ = @import("gdt_ledger"); }` module import collects zero tests, so
// the tested module must be src/root.zig itself; (2) `@import("root")` in an
// addTest build resolves to the TEST RUNNER module, so the per-mode policy
// must be declared in a custom simple-mode runner (tests/runner_*.zig), not
// on the tested module. Every mode step used to report "1 pass (1 total)".
fn addModeTestRun(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    runner_path: []const u8,
    check_step: *std.Build.Step,
) *std.Build.Step {
    const tests = b.addTest(.{
        .root_module = createLedgerModule(b, target, optimize),
        .test_runner = .{ .path = b.path(runner_path), .mode = .simple },
    });
    const run_tests = b.addRunArtifact(tests);

    check_step.dependOn(&tests.step);
    return &run_tests.step;
}

fn createScopedTestRootModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const ledger_mod = createLedgerModule(b, target, optimize);
    const scoped_dep_mod = b.createModule(.{
        .root_source_file = b.path("tests/scoped_module.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gdt_ledger", .module = ledger_mod },
        },
    });
    return b.createModule(.{
        .root_source_file = b.path("tests/scoped.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gdt_ledger", .module = ledger_mod },
            .{ .name = "scoped_module", .module = scoped_dep_mod },
        },
    });
}

fn addExeSmokeRun(
    b: *std.Build,
    root_module: *std.Build.Module,
    check_step: *std.Build.Step,
) *std.Build.Step {
    const exe = b.addExecutable(.{
        .name = "test-scoped",
        .root_module = root_module,
    });
    const run = b.addRunArtifact(exe);

    check_step.dependOn(&exe.step);
    return &run.step;
}

fn createFuzzTestModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn createFuzzTestArtifact(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    filter: ?[]const u8,
) *std.Build.Step.Compile {
    const filters = if (filter) |name| blk: {
        const list = b.allocator.alloc([]const u8, 1) catch @panic("OOM");
        list[0] = name;
        break :blk list;
    } else &.{};

    return b.addTest(.{
        .root_module = createFuzzTestModule(b, target, optimize),
        .filters = filters,
    });
}

fn addFuzzCompile(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    check_step: *std.Build.Step,
) void {
    const tests = createFuzzTestArtifact(b, target, optimize, null);
    check_step.dependOn(&tests.step);
}

fn addFuzzRun(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    filter: []const u8,
) *std.Build.Step {
    const tests = createFuzzTestArtifact(b, target, optimize, filter);
    const run_tests = b.addRunArtifact(tests);

    return &run_tests.step;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const requested_mode = b.option(LedgerMode, "ledger-mode", "example root default mode (full, guardrails, off)") orelse .full;

    const check_step = b.step("check", "Check compilation");

    const example_options = b.addOptions();
    example_options.addOption(LedgerMode, "default_mode", requested_mode);

    const ledger_mod = b.addModule("gdt_ledger", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const scoped_mod = createScopedTestRootModule(b, target, optimize);

    const test_full = addModeTestRun(b, target, optimize, "tests/runner_full.zig", check_step);
    const test_guardrails = addModeTestRun(b, target, optimize, "tests/runner_guardrails.zig", check_step);
    const test_off = addModeTestRun(b, target, optimize, "tests/runner_off.zig", check_step);

    // Scoped policy stays an executable because b.addTest did not make ledger's
    // @import("root") see the app-root scoped policy correctly in this setup.
    const test_scoped = addExeSmokeRun(b, scoped_mod, check_step);
    addFuzzCompile(b, target, optimize, check_step);

    // Umbrella step: `zig build test` = the full mode matrix + scoped + check.
    const test_all = b.step("test", "Run all gdt-ledger test suites and checks");
    test_all.dependOn(test_full);
    test_all.dependOn(test_guardrails);
    test_all.dependOn(test_off);
    test_all.dependOn(test_scoped);
    test_all.dependOn(check_step);

    const fuzz_all = b.step("fuzz", "Run gdt-ledger fuzz targets (use -Doptimize=ReleaseSafe --fuzz=<N>)");
    const fuzz_filters = [_][]const u8{
        "fuzz tracked allocator state machine",
        "fuzz meter protocol state machine",
        "fuzz zone-core hierarchy accounting",
        "fuzz writeJsonString emits parseable JSON strings",
    };
    for (fuzz_filters) |filter| {
        fuzz_all.dependOn(addFuzzRun(b, target, optimize, filter));
    }

    // --- Negative compile checks (app-root policy validation) ---
    const compile_fail_cases = [_]struct {
        path: []const u8,
        stderr_match: []const u8,
    }{
        .{ .path = "tests/compile_fail/unknown_option.zig", .stderr_match = "unknown gdt_ledger_options field 'defualt_mode'" },
        .{ .path = "tests/compile_fail/unknown_rule_field.zig", .stderr_match = "unknown gdt_ledger_options rule field 'level'" },
        .{ .path = "tests/compile_fail/duplicate_rule_scope.zig", .stderr_match = "duplicate rule scope 'gdt_vulkan'" },
        .{ .path = "tests/compile_fail/dead_rule.zig", .stderr_match = "dead rule: scope 'gdt_vulcan' matches no known scoped zone path" },
        .{ .path = "tests/compile_fail/full_without_runtime.zig", .stderr_match = ".full requires root.gdt_ledger_runtime" },
        .{ .path = "tests/compile_fail/wrong_runtime_type.zig", .stderr_match = "gdt_ledger_runtime must be a ledger.RootRuntime (found 'u32')" },
        .{ .path = "tests/compile_fail/const_runtime.zig", .stderr_match = "gdt_ledger_runtime must be declared 'pub var', not 'pub const'" },
        .{ .path = "tests/compile_fail/subzone_init.zig", .stderr_match = "subzones use initUnder" },
        .{ .path = "tests/compile_fail/tracy_enabled.zig", .stderr_match = ".tracy = true is not implemented yet" },
        .{ .path = "tests/compile_fail/fixed_buffer_subzone.zig", .stderr_match = "ZonedFixedBuffer does not support subzones" },
        .{ .path = "tests/compile_fail/bad_rule_path.zig", .stderr_match = "rule scope must not contain empty path segments" },
    };

    for (compile_fail_cases) |case| {
        const run = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build-exe",
            "-fno-emit-bin",
            "-fno-compiler-rt",
            "-fno-ubsan-rt",
            "--dep",
            "gdt_ledger",
            b.fmt("-Mroot={s}", .{b.path(case.path).getPath(b)}),
            b.fmt("-Mgdt_ledger={s}", .{b.path("src/root.zig").getPath(b)}),
        });
        run.expectExitCode(1);
        run.expectStdErrMatch(case.stderr_match);
        check_step.dependOn(&run.step);
    }

    // --- Examples ---
    const examples = [_]struct {
        name: []const u8,
        src: []const u8,
        desc: []const u8,
        uses_mode_option: bool = false,
    }{
        .{ .name = "run-basic", .src = "examples/basic.zig", .desc = "Basic zone allocation and runtime dump" },
        .{ .name = "run-subzones", .src = "examples/subzones.zig", .desc = "Hierarchical parent/child zones" },
        .{ .name = "run-build-modes", .src = "examples/build_modes.zig", .desc = "Void elimination across build modes", .uses_mode_option = true },
        .{ .name = "run-wrappers", .src = "examples/wrappers.zig", .desc = "ZonedArena, ZonedPool, ZonedFixedBuffer, ZonedDebug" },
        .{ .name = "run-engine", .src = "examples/engine.zig", .desc = "Engine/app integration with subsystem piping" },
        .{ .name = "run-leak-hunt", .src = "examples/leak_hunt.zig", .desc = "ZonedDebug pairing: ledger + DebugAllocator, two verdicts one deinit" },
        .{ .name = "run-readme", .src = "examples/readme.zig", .desc = "Example from Quick Flex in README.md" },
    };

    for (examples) |example| {
        const root_module = b.createModule(.{
            .root_source_file = b.path(example.src),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gdt_ledger", .module = ledger_mod },
            },
        });

        if (example.uses_mode_option) {
            root_module.addOptions("gdt_ledger_example_options", example_options);
        }

        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = root_module,
        });

        const run = b.addRunArtifact(exe);
        b.step(example.name, example.desc).dependOn(&run.step);

        check_step.dependOn(&exe.step);
    }
}
