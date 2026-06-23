//! An engine mockup: how to wire zones into a subsystem layout.
//!
//! The subsystems are stubs (one allocation each, no real simulation) -- the
//! point is the wiring, not the work. Zone *types* live at module scope (the
//! `zones` namespace), the runtime storage is owned by the application root, and
//! each subsystem is handed only the allocator(s) it should draw from: physics
//! from the physics zone, the renderer from render, AI from an arena subzone used
//! as per-think scratch. The zone tree (`engine` over `physics` / `render` / `ai`,
//! with `ai` itself parenting a `scratch` arena) mirrors the subsystem layout, so
//! the end-of-frame dump reads like the engine's own structure -- printed as both
//! text and JSON.
//!
//! Best practices on display: subsystems take allocators as parameters and never
//! reach for a global; the zone set is built with `errdefer` so a failure partway
//! through `init` unwinds the zones already created; and teardown runs
//! children-first, because a child charges its bytes through the parent that
//! backs it and must be gone before that parent.
//!
//! Run: `zig build run-engine`.

const std = @import("std");
const ledger = @import("gdt_ledger");

pub const gdt_ledger_options = .{
    .default_mode = .full,
};

pub var gdt_ledger_runtime: ledger.RootRuntime = .{};

const zones = struct {
    const Io = ledger.Zone(.{
        .name = "io",
        .budget = 4096,
    });

    const Engine = ledger.Zone(.{
        .name = "engine",
        .budget = 256 * 1024,
        .hardcap = 512 * 1024,
        .frame_tracking = true,
    });

    const Physics = Engine.subzone(.{
        .name = "physics",
        .budget = 64 * 1024,
    });

    const Render = Engine.subzone(.{
        .name = "render",
        .budget = 128 * 1024,
    });

    const AI = Engine.subzone(.{
        .name = "ai",
        .budget = 32 * 1024,
    });

    const AIScratch = ledger.ZonedArena(AI.subzone(.{
        .name = "scratch",
        .budget = 8 * 1024,
    }));
};

const AppZones = struct {
    io: zones.Io,
    engine: zones.Engine,
    physics: zones.Physics,
    render: zones.Render,
    ai: zones.AI,

    fn init(backing: std.mem.Allocator, control: std.mem.Allocator) !AppZones {
        var self: AppZones = undefined;

        self.io = try zones.Io.init(.{
            .backing_allocator = backing,
            .control_allocator = control,
        });
        // Each errdefer tears down the zones built so far if a later init fails,
        // so a partial AppZones never leaks.
        errdefer _ = self.io.deinit();

        self.engine = try zones.Engine.init(.{
            .backing_allocator = backing,
            .control_allocator = control,
        });
        errdefer _ = self.engine.deinit();

        self.physics = try zones.Physics.initUnder(.{ .parent = &self.engine });
        errdefer _ = self.physics.deinit();

        self.render = try zones.Render.initUnder(.{ .parent = &self.engine });
        errdefer _ = self.render.deinit();

        self.ai = try zones.AI.initUnder(.{ .parent = &self.engine });
        errdefer _ = self.ai.deinit();

        return self;
    }

    fn deinit(self: *AppZones) void {
        // Reverse of init order: every child deinits before the parent it charged
        // its allocations through.
        std.debug.assert(self.ai.deinit() == .ok);
        std.debug.assert(self.render.deinit() == .ok);
        std.debug.assert(self.physics.deinit() == .ok);
        std.debug.assert(self.engine.deinit() == .ok);
        std.debug.assert(self.io.deinit() == .ok);
    }
};

const PhysicsSystem = struct {
    allocator: std.mem.Allocator,
    data: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator) PhysicsSystem {
        return .{ .allocator = allocator };
    }

    fn simulate(self: *PhysicsSystem) !void {
        self.data = try self.allocator.alloc(u8, 1024);
    }

    fn deinit(self: *PhysicsSystem) void {
        if (self.data) |d| self.allocator.free(d);
    }
};

const Renderer = struct {
    const Allocators = struct {
        main: std.mem.Allocator,
        scratch: std.mem.Allocator,
    };

    allocators: Allocators,
    gpu_buffer: ?[]u8 = null,

    fn init(allocators: Allocators) Renderer {
        return .{ .allocators = allocators };
    }

    fn draw(self: *Renderer) !void {
        self.gpu_buffer = try self.allocators.main.alloc(u8, 2048);
    }

    fn deinit(self: *Renderer) void {
        if (self.gpu_buffer) |b| self.allocators.main.free(b);
    }
};

const AISystem = struct {
    scratch: zones.AIScratch,
    plan: ?[]u8 = null,

    fn init(parent_zone: *zones.AI) !AISystem {
        return .{
            .scratch = try zones.AIScratch.initUnder(.{ .parent = parent_zone }),
        };
    }

    fn think(self: *AISystem) !void {
        const ally = self.scratch.allocator();
        self.plan = try ally.alloc(u8, 512);
    }

    fn deinit(self: *AISystem) void {
        if (self.plan) |p| self.scratch.allocator().free(p);
        _ = self.scratch.reset(.free_all);
        std.debug.assert(self.scratch.deinit() == .ok);
    }
};

const App = struct {
    zones: *AppZones,
    physics: PhysicsSystem,
    renderer: Renderer,
    ai: AISystem,

    fn init(z: *AppZones) !App {
        return .{
            .zones = z,
            .physics = PhysicsSystem.init(z.physics.allocator()),
            .renderer = Renderer.init(.{
                .main = z.render.allocator(),
                .scratch = z.render.allocator(),
            }),
            .ai = try AISystem.init(&z.ai),
        };
    }

    fn run(self: *App) !void {
        try self.physics.simulate();
        try self.renderer.draw();
        try self.ai.think();
    }

    fn deinit(self: *App) void {
        self.ai.deinit();
        self.renderer.deinit();
        self.physics.deinit();
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();

    var app_zones = try AppZones.init(gpa, gpa);

    var threaded: std.Io.Threaded = .init(app_zones.io.allocator(), .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    const io = threaded.io();

    var app = try App.init(&app_zones);
    try app.run();

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buf);
    const out = &file_writer.interface;

    try out.print("=== Zone tree after one frame ===\n\n", .{});
    try ledger.dumpToWriter(out);

    try out.print("\n=== JSON export ===\n", .{});
    try ledger.dumpToJson(out);
    try out.print("\n", .{});
    try out.flush();

    app.deinit();
    threaded.deinit();
    app_zones.deinit();
}
