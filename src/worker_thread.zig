const std = @import("std");
const GeneticAlgorithm = @import("genetic_algorithm.zig").GeneticAlgorithm;
const WorkerContext = @import("worker_context.zig").WorkerContext;

pub fn workerThread(ctx: *WorkerContext) !void {
    var prng = std.Random.DefaultPrng.init(ctx.seed + ctx.core_id * 1000);
    const random = prng.random();

    std.debug.print("  [Core {d}] Starting evolution...\n", .{ctx.core_id});

    var ga = try GeneticAlgorithm.init(
        ctx.allocator,
        ctx.pieces,
        ctx.strip_height,
        ctx.population_size,
        ctx.elite_size,
        ctx.mutant_size,
        random,
        ctx.piece_constraints,
    );
    defer ga.deinit();

    ga.initializePopulation();
    try ga.evaluateAll();

    for (0..ctx.generations) |gen| {
        try ga.evolveOneGeneration();

        var best_idx: usize = 0;
        for (ga.population, 0..) |chromo, i| {
            if (chromo.fitness < ga.population[best_idx].fitness) {
                best_idx = i;
            }
        }

        const current_best = ga.population[best_idx].fitness;

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

                std.debug.print("  [Core {d}] Gen {d}: Migration (imported {d:.2})\n", .{ ctx.core_id, gen, imported.fitness });
            }
        }

        if ((gen + 1) % 20 == 0) {
            std.debug.print("  [Core {d}] Gen {d}/{d}: Best = {d:.2}\n", .{ ctx.core_id, gen + 1, ctx.generations, current_best });
        }
    }

    var best_idx: usize = 0;
    for (ga.population, 0..) |chromo, i| {
        if (chromo.fitness < ga.population[best_idx].fitness) {
            best_idx = i;
        }
    }

    ctx.best_result = try ga.population[best_idx].clone();
    ctx.best_fitness = ctx.best_result.fitness;

    std.debug.print("  [Core {d}] Finished! Best fitness: {d:.2}\n", .{ ctx.core_id, ctx.best_fitness });
}
