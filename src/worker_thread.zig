const std = @import("std");
const GeneticAlgorithm = @import("genetic_algorithm.zig").GeneticAlgorithm;
const WorkerContext = @import("worker_context.zig").WorkerContext;

/// SplitMix64 hash to derive an independent seed per core.
fn deriveSeed(base: u64, core_id: usize) u64 {
    var s = base +% @as(u64, @intCast(core_id)) *% 0x9e3779b97f4a7c15;
    s = (s ^ (s >> 30)) *% 0xbf58476d1ce4e5b9;
    s = (s ^ (s >> 27)) *% 0x94d049bb133111eb;
    return s ^ (s >> 31);
}

pub fn workerThread(ctx: *WorkerContext) !void {
    var prng = std.Random.DefaultPrng.init(deriveSeed(ctx.seed, ctx.core_id));
    const random = prng.random();

    if (ctx.verbose) std.debug.print("  [Core {d}] Starting evolution...\n", .{ctx.core_id});

    var ga = try GeneticAlgorithm.init(
        ctx.allocator,
        ctx.pieces,
        ctx.strip_width,
        ctx.grid_resolution,
        ctx.population_size,
        ctx.elite_size,
        ctx.mutant_size,
        random,
        ctx.piece_constraints,
    );
    defer ga.deinit();

    ga.use_nfp = ctx.use_nfp;
    ga.mutation_rate = ctx.mutation_rate;
    ga.shared_fitness_cache = ctx.shared_fitness_cache;
    ga.shared_nfp_cache = ctx.shared_nfp_cache;
    ga.initializePopulation();
    try ga.evaluateAll();

    var stagnation_count: usize = 0;
    var last_best: f32 = std.math.floatMax(f32);

    for (0..ctx.generations) |gen| {
        try ga.evolveOneGeneration();

        var best_idx: usize = 0;
        for (ga.population, 0..) |chromo, i| {
            if (chromo.fitness < ga.population[best_idx].fitness) {
                best_idx = i;
            }
        }

        const current_best = ga.population[best_idx].fitness;

        // Stagnation tracking
        if (current_best < last_best) {
            last_best = current_best;
            stagnation_count = 0;
        } else {
            stagnation_count += 1;
        }

        // Migration
        if (gen % ctx.migration_interval == 0 and gen > 0) {
            try ctx.migration_pool.submitBest(ctx.core_id, ga.population[best_idx]);

            if (try ctx.migration_pool.importBest(ctx.core_id)) |imported_const| {
                var imported = imported_const;
                defer imported.deinit();

                var worst_idx: usize = 0;
                for (ga.population, 0..) |chromo, i| {
                    if (chromo.fitness > ga.population[worst_idx].fitness) {
                        worst_idx = i;
                    }
                }
                ga.population[worst_idx].deinit();
                ga.population[worst_idx] = try imported.clone();

                if (ctx.verbose) std.debug.print("  [Core {d}] Gen {d}: Migration (imported {d:.2})\n", .{ ctx.core_id, gen, imported.fitness });

                // Reset stagnation immediately if the imported solution beats our local best.
                if (imported.fitness < last_best) {
                    last_best = imported.fitness;
                    stagnation_count = 0;
                }
            }
        }

        if (ctx.verbose and (gen + 1) % 20 == 0) {
            std.debug.print("  [Core {d}] Gen {d}/{d}: Best = {d:.2}\n", .{ ctx.core_id, gen + 1, ctx.generations, current_best });
        }

        if (ctx.stagnation_limit > 0 and stagnation_count >= ctx.stagnation_limit) {
            if (ctx.verbose) std.debug.print("  [Core {d}] Early stop at gen {d} (no improvement for {d} generations)\n", .{ ctx.core_id, gen + 1, ctx.stagnation_limit });
            break;
        }

        if (ctx.timeout_end_ms) |deadline| {
            if (std.time.milliTimestamp() >= deadline) {
                if (ctx.verbose) std.debug.print("  [Core {d}] Timeout at gen {d}\n", .{ ctx.core_id, gen + 1 });
                break;
            }
        }
    }

    var best_idx: usize = 0;
    for (ga.population, 0..) |chromo, i| {
        if (chromo.fitness < ga.population[best_idx].fitness) {
            best_idx = i;
        }
    }

    ctx.best_result = try ga.population[best_idx].clone();
    ctx.best_fitness = ctx.best_result.?.fitness;

    if (ctx.verbose) std.debug.print("  [Core {d}] Finished! Best fitness: {d:.2}\n", .{ ctx.core_id, ctx.best_fitness });
}
