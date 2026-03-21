const std = @import("std");
const Vec2 = @import("vec2.zig").Vec2;
const Polygon = @import("polygon.zig").Polygon;
const PlacedItem = @import("placed_item.zig").PlacedItem;
const Chromosome = @import("chromosome.zig").Chromosome;
const PieceConstraints = @import("piece_constraints.zig").PieceConstraints;
const GeneticAlgorithm = @import("genetic_algorithm.zig").GeneticAlgorithm;
const MigrationPool = @import("migration_pool.zig").MigrationPool;
const WorkerContext = @import("worker_context.zig").WorkerContext;
const NestingResult = @import("nesting_result.zig").NestingResult;
const Packer = @import("packer.zig").Packer;
const generateRandomConvex = @import("helpers.zig").generateRandomConvex;
const exportToSVG = @import("helpers.zig").exportToSVG;
const workerThread = @import("worker_thread.zig").workerThread;

pub const NestingConfig = struct {
    strip_width: f32,
    num_cores: usize = 4,
    population_per_core: usize = 20,
    generations: usize = 100,
    migration_interval: usize = 10,
    /// Stop early if best fitness does not improve for this many generations. 0 = disabled.
    stagnation_limit: usize = 20,
    grid_resolution: f32 = 5.0,
    verbose: bool = false,
    piece_constraints: ?[]const PieceConstraints = null,
};

pub const NestingError = error{
    NoPieces,
    InvalidStripWidth,
    InvalidNumCores,
    InvalidGridResolution,
    PieceTooWideForStrip,
};

pub fn performNesting(
    allocator: std.mem.Allocator,
    pieces: []Polygon,
    config: NestingConfig,
) !NestingResult {
    if (pieces.len == 0) return NestingError.NoPieces;
    if (config.strip_width <= 0) return NestingError.InvalidStripWidth;
    if (config.num_cores == 0) return NestingError.InvalidNumCores;
    if (config.grid_resolution <= 0) return NestingError.InvalidGridResolution;
    var use_nfp = false;
    for (pieces) |p| {
        if (p.height > config.strip_width) return NestingError.PieceTooWideForStrip;
        if (!p.isConvex()) use_nfp = true;
    }

    const elite_size: usize = @intFromFloat(@as(f32, @floatFromInt(config.population_per_core)) * 0.3);
    const mutant_size: usize = @intFromFloat(@as(f32, @floatFromInt(config.population_per_core)) * 0.2);

    if (config.verbose) {
        std.debug.print("\nMulti-core GA Parameters:\n", .{});
        std.debug.print("   Cores: {d}\n", .{config.num_cores});
        std.debug.print("   Population per core: {d}\n", .{config.population_per_core});
        std.debug.print("   Total population: {d}\n", .{config.population_per_core * config.num_cores});
        std.debug.print("   Elite: {d} (30%), Mutants: {d} (20%)\n", .{ elite_size, mutant_size });
        std.debug.print("   Generations: {d} (max)\n", .{config.generations});
        std.debug.print("   Migration interval: every {d} generations\n", .{config.migration_interval});
        std.debug.print("   Grid resolution: {d:.1}\n", .{config.grid_resolution});
        std.debug.print("   Rotations: 8 angles (0, 45, 90, 135, 180, 225, 270, 315 deg)\n\n", .{});
    }

    var migration_pool = try MigrationPool.init(allocator, config.num_cores, pieces.len);
    defer migration_pool.deinit();

    var contexts = try allocator.alloc(WorkerContext, config.num_cores);
    defer allocator.free(contexts);

    const seed = @as(u64, @intCast(std.time.timestamp()));

    for (contexts, 0..) |*ctx, i| {
        ctx.* = .{
            .core_id = i,
            .pieces = pieces,
            .piece_constraints = config.piece_constraints,
            .strip_width = config.strip_width,
            .population_size = config.population_per_core,
            .elite_size = elite_size,
            .mutant_size = mutant_size,
            .generations = config.generations,
            .migration_pool = &migration_pool,
            .migration_interval = config.migration_interval,
            .grid_resolution = config.grid_resolution,
            .stagnation_limit = config.stagnation_limit,
            .allocator = allocator,
            .seed = seed,
            .verbose = config.verbose,
            .use_nfp = use_nfp,
        };
    }

    const threads = try allocator.alloc(std.Thread, config.num_cores);
    defer allocator.free(threads);

    const start_time = std.time.milliTimestamp();
    if (config.verbose) std.debug.print("Spawning {d} worker threads...\n\n", .{config.num_cores});

    for (threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, workerThread, .{&contexts[i]});
    }

    for (threads) |thread| {
        thread.join();
    }

    const elapsed = std.time.milliTimestamp() - start_time;

    var global_best_idx: usize = 0;
    for (contexts, 0..) |ctx, i| {
        if (ctx.best_fitness < contexts[global_best_idx].best_fitness) {
            global_best_idx = i;
        }
    }

    if (config.verbose) {
        std.debug.print("\nMulti-core GA Complete!\n", .{});
        std.debug.print("   Best solution from: Core {d}\n", .{global_best_idx});
        std.debug.print("   Best fitness (strip length used): {d:.2}\n", .{contexts[global_best_idx].best_fitness});
        std.debug.print("   Total time: {d}ms ({d:.1}s)\n", .{ elapsed, @as(f32, @floatFromInt(elapsed)) / 1000.0 });
        std.debug.print("   Time per piece: {d:.1}s\n", .{@as(f32, @floatFromInt(elapsed)) / 1000.0 / @as(f32, @floatFromInt(pieces.len))});
        std.debug.print("\nCreating final packing from best solution...\n", .{});
    }

    const best_chromo = contexts[global_best_idx].best_result;

    var final_packer = Packer.init(allocator, config.strip_width, config.grid_resolution);
    final_packer.use_nfp = use_nfp;
    defer final_packer.deinit();

    var skipped_pieces: usize = 0;
    for (best_chromo.sequence) |piece_idx| {
        const orig_poly = pieces[piece_idx];
        var rotated = try orig_poly.rotateByAngle(allocator, best_chromo.rotations[piece_idx]);
        defer rotated.deinit(allocator);

        if (try final_packer.placePolygon(rotated, piece_idx, best_chromo.rotations[piece_idx])) |placement| {
            try final_packer.placed_items.append(allocator, placement);
        } else {
            skipped_pieces += 1;
            if (config.verbose) {
                std.debug.print("   Warning: Piece {d} could not be placed (size: {d:.1}x{d:.1}, strip width: {d:.1})\n", .{
                    piece_idx,
                    rotated.width,
                    rotated.height,
                    config.strip_width,
                });
            }
        }
    }

    if (config.verbose) {
        if (skipped_pieces > 0) {
            std.debug.print("   Warning: {d}/{d} pieces were skipped (too large or no space)\n", .{
                skipped_pieces,
                pieces.len,
            });
        }
        const final_length = final_packer.getLength();
        std.debug.print("   Strip dimensions: {d:.2} x {d:.2}\n", .{ final_length, config.strip_width });
        std.debug.print("   Efficiency: {d:.2}%\n", .{final_packer.calculateEfficiency()});
    }

    const final_length = final_packer.getLength();
    const efficiency = final_packer.calculateEfficiency();

    var result_items = std.ArrayList(PlacedItem){};
    for (final_packer.placed_items.items) |item| {
        const cloned_poly = try item.poly.clone(allocator);
        try result_items.append(allocator, PlacedItem{
            .poly = cloned_poly,
            .pos = item.pos,
            .rotation = item.rotation,
            .piece_id = item.piece_id,
        });
    }

    for (contexts) |*ctx| {
        ctx.best_result.deinit();
    }

    return NestingResult{
        .placed_items = result_items,
        .best_fitness = contexts[global_best_idx].best_fitness,
        .efficiency = efficiency,
        .final_length = final_length,
        .allocator = allocator,
    };
}

fn makeSquare(allocator: std.mem.Allocator, size: f32) !Polygon {
    const v = try allocator.alloc(Vec2, 4);
    v[0] = Vec2.init(0, 0);
    v[1] = Vec2.init(size, 0);
    v[2] = Vec2.init(size, size);
    v[3] = Vec2.init(0, size);
    var p = Polygon{ .vertices = v };
    p.initBoundingBox();
    return p;
}

test "performNesting - NoPieces error" {
    const allocator = std.testing.allocator;
    var pieces = [_]Polygon{};
    const result = performNesting(allocator, &pieces, .{ .strip_width = 10 });
    try std.testing.expectError(NestingError.NoPieces, result);
}

test "performNesting - InvalidStripWidth error" {
    const allocator = std.testing.allocator;
    var sq = try makeSquare(allocator, 5);
    defer sq.deinit(allocator);
    var pieces = [_]Polygon{sq};
    try std.testing.expectError(NestingError.InvalidStripWidth, performNesting(allocator, &pieces, .{ .strip_width = 0 }));
    try std.testing.expectError(NestingError.InvalidStripWidth, performNesting(allocator, &pieces, .{ .strip_width = -1 }));
}

test "performNesting - InvalidNumCores error" {
    const allocator = std.testing.allocator;
    var sq = try makeSquare(allocator, 5);
    defer sq.deinit(allocator);
    var pieces = [_]Polygon{sq};
    try std.testing.expectError(NestingError.InvalidNumCores, performNesting(allocator, &pieces, .{ .strip_width = 10, .num_cores = 0 }));
}

test "performNesting - InvalidGridResolution error" {
    const allocator = std.testing.allocator;
    var sq = try makeSquare(allocator, 5);
    defer sq.deinit(allocator);
    var pieces = [_]Polygon{sq};
    try std.testing.expectError(NestingError.InvalidGridResolution, performNesting(allocator, &pieces, .{ .strip_width = 10, .grid_resolution = 0 }));
}

test "performNesting - PieceTooWideForStrip error" {
    const allocator = std.testing.allocator;
    var sq = try makeSquare(allocator, 10);
    defer sq.deinit(allocator);
    var pieces = [_]Polygon{sq};
    // piece height (10) > strip_width (5)
    try std.testing.expectError(NestingError.PieceTooWideForStrip, performNesting(allocator, &pieces, .{ .strip_width = 5 }));
}

test "performNesting - non-convex L-shape is accepted and nested" {
    const allocator = std.testing.allocator;
    // L-shape: not convex — should succeed with NFP-based collision detection
    const v = try allocator.alloc(Vec2, 6);
    v[0] = Vec2.init(0, 0);
    v[1] = Vec2.init(2, 0);
    v[2] = Vec2.init(2, 1);
    v[3] = Vec2.init(1, 1);
    v[4] = Vec2.init(1, 2);
    v[5] = Vec2.init(0, 2);
    var lshape = Polygon{ .vertices = v };
    lshape.initBoundingBox();
    defer lshape.deinit(allocator);
    var pieces = [_]Polygon{lshape};
    var result = try performNesting(allocator, &pieces, .{ .strip_width = 10, .num_cores = 1, .generations = 1 });
    defer result.deinit();
    try std.testing.expect(result.placed_items.items.len == 1);
}

test "performNesting with random convex polygons" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(12345); // Fixed seed for reproducibility
    const random = prng.random();

    const num_cores = 4;
    const num_pieces = 10;
    var pieces = std.ArrayList(Polygon){};
    defer {
        for (pieces.items) |*p| p.deinit(allocator);
        pieces.deinit(allocator);
    }

    for (0..num_pieces) |_| {
        const size = 5.0 + random.float(f32) * 8.0;
        try pieces.append(allocator, try generateRandomConvex(allocator, random, size));
    }

    var result = try performNesting(allocator, pieces.items, .{
        .strip_width = 50.0,
        .num_cores = num_cores,
        .population_per_core = 10,
        .generations = 50,
        .migration_interval = 10,
    });
    defer result.deinit();

    // Debug output
    std.debug.print("\n📊 Test Results:\n", .{});
    std.debug.print("   Pieces placed: {d}/{d}\n", .{ result.placed_items.items.len, num_pieces });
    std.debug.print("   Final width: {d:.2}\n", .{result.final_length});
    std.debug.print("   Best fitness: {d:.2}\n", .{result.best_fitness});
    std.debug.print("   Efficiency: {d:.2}%\n\n", .{result.efficiency});

    // Verify we got valid results
    try std.testing.expect(result.placed_items.items.len > 0);
    try std.testing.expect(result.final_length > 0);
    try std.testing.expect(result.efficiency > 0);
    try std.testing.expect(result.best_fitness > 0);
}
