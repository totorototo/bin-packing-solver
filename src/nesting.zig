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

pub fn performNesting(
    allocator: std.mem.Allocator,
    pieces: []Polygon,
    strip_height: f32,
    num_cores: usize,
    population_per_core: usize,
    generations: usize,
    migration_interval: usize,
) !NestingResult {
    return performNestingWithConstraints(
        allocator,
        pieces,
        null, // No rotation constraints
        strip_height,
        num_cores,
        population_per_core,
        generations,
        migration_interval,
    );
}

pub fn performNestingWithConstraints(
    allocator: std.mem.Allocator,
    pieces: []Polygon,
    piece_constraints: ?[]const PieceConstraints,
    strip_height: f32,
    num_cores: usize,
    population_per_core: usize,
    generations: usize,
    migration_interval: usize,
) !NestingResult {
    const elite_size: usize = @intFromFloat(@as(f32, @floatFromInt(population_per_core)) * 0.3);
    const mutant_size: usize = @intFromFloat(@as(f32, @floatFromInt(population_per_core)) * 0.2);

    std.debug.print("\n🧬 Multi-core GA Parameters:\n", .{});
    std.debug.print("   Cores: {d}\n", .{num_cores});
    std.debug.print("   Population per core: {d}\n", .{population_per_core});
    std.debug.print("   Total population: {d}\n", .{population_per_core * num_cores});
    std.debug.print("   Elite: {d} ({d}%), Mutants: {d} ({d}%)\n", .{ elite_size, 30, mutant_size, 20 });
    std.debug.print("   Generations: {d} (max)\n", .{generations});
    std.debug.print("   Migration interval: every {d} generations\n", .{migration_interval});
    std.debug.print("   Rotations: 8 angles (0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°)\n\n", .{});

    var migration_pool = try MigrationPool.init(allocator, num_cores, pieces.len);
    defer migration_pool.deinit();

    var contexts = try allocator.alloc(WorkerContext, num_cores);
    defer allocator.free(contexts);

    const seed = @as(u64, @intCast(std.time.timestamp()));

    for (contexts, 0..) |*ctx, i| {
        ctx.* = .{
            .core_id = i,
            .pieces = pieces,
            .piece_constraints = piece_constraints,
            .strip_height = strip_height,
            .population_size = population_per_core,
            .elite_size = elite_size,
            .mutant_size = mutant_size,
            .generations = generations,
            .migration_pool = &migration_pool,
            .migration_interval = migration_interval,
            .allocator = allocator,
            .seed = seed,
        };
    }

    const threads = try allocator.alloc(std.Thread, num_cores);
    defer allocator.free(threads);

    const start_time = std.time.milliTimestamp();
    std.debug.print("⚡ Spawning {d} worker threads...\n\n", .{num_cores});

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

    std.debug.print("\n✅ Multi-core GA Complete!\n", .{});
    std.debug.print("   Best solution from: Core {d}\n", .{global_best_idx});
    std.debug.print("   Best fitness (strip length): {d:.2}\n", .{contexts[global_best_idx].best_fitness});
    std.debug.print("   Total time: {d}ms ({d:.1}s)\n", .{ elapsed, @as(f32, @floatFromInt(elapsed)) / 1000.0 });
    std.debug.print("   Time per piece: {d:.1}s\n", .{@as(f32, @floatFromInt(elapsed)) / 1000.0 / @as(f32, @floatFromInt(pieces.len))});

    // Create final packing from best chromosome
    std.debug.print("\n📦 Creating final packing from best solution...\n", .{});
    const best_chromo = contexts[global_best_idx].best_result;

    var final_packer = Packer.init(allocator, strip_height);
    defer final_packer.deinit();

    var skipped_pieces: usize = 0;
    for (best_chromo.sequence) |piece_idx| {
        const orig_poly = pieces[piece_idx];
        var rotated = try orig_poly.rotateByAngle(allocator, best_chromo.rotations[piece_idx]);
        defer rotated.deinit(allocator);

        if (try final_packer.placePolygon(rotated, piece_idx)) |placement| {
            try final_packer.placed_items.append(allocator, placement);
        } else {
            skipped_pieces += 1;
            std.debug.print("   ⚠️  Piece {d} could not be placed (size: {d:.1}x{d:.1}, strip height: {d:.1})\n", .{
                piece_idx,
                rotated.width,
                rotated.height,
                strip_height,
            });
        }
    }

    if (skipped_pieces > 0) {
        std.debug.print("   ⚠️  Warning: {d}/{d} pieces were skipped (too large or no space)\n", .{
            skipped_pieces,
            pieces.len,
        });
    }

    const final_width = final_packer.getMaxWidth();
    const efficiency = final_packer.calculateEfficiency();

    std.debug.print("   Strip dimensions: {d:.2} x {d:.2}\n", .{ final_width, strip_height });
    std.debug.print("   Efficiency: {d:.2}%\n", .{efficiency});

    // Clone placed items for the result
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

    // Clean up worker results
    for (contexts) |*ctx| {
        ctx.best_result.deinit();
    }

    return NestingResult{
        .placed_items = result_items,
        .best_fitness = contexts[global_best_idx].best_fitness,
        .efficiency = efficiency,
        .final_width = final_width,
        .allocator = allocator,
    };
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

    const strip_height: f32 = 50.0;
    const population_per_core: usize = 10;
    const generations: usize = 50;
    const migration_interval: usize = 10;

    var result = try performNesting(
        allocator,
        pieces.items,
        strip_height,
        num_cores,
        population_per_core,
        generations,
        migration_interval,
    );
    defer result.deinit();

    // Debug output
    std.debug.print("\n📊 Test Results:\n", .{});
    std.debug.print("   Pieces placed: {d}/{d}\n", .{ result.placed_items.items.len, num_pieces });
    std.debug.print("   Final width: {d:.2}\n", .{result.final_width});
    std.debug.print("   Best fitness: {d:.2}\n", .{result.best_fitness});
    std.debug.print("   Efficiency: {d:.2}%\n\n", .{result.efficiency});

    // Verify we got valid results
    try std.testing.expect(result.placed_items.items.len > 0);
    try std.testing.expect(result.final_width > 0);
    try std.testing.expect(result.efficiency > 0);
    try std.testing.expect(result.best_fitness > 0);
}
