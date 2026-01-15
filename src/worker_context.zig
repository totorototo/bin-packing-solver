const std = @import("std");
const Chromosome = @import("chromosome.zig").Chromosome;
const Polygon = @import("polygon.zig").Polygon;
const PieceConstraints = @import("piece_constraints.zig").PieceConstraints;
const MigrationPool = @import("migration_pool.zig").MigrationPool;

pub const WorkerContext = struct {
    core_id: usize,
    pieces: []Polygon,
    piece_constraints: ?[]const PieceConstraints = null,
    strip_height: f32,
    population_size: usize,
    elite_size: usize,
    mutant_size: usize,
    generations: usize,
    migration_pool: *MigrationPool,
    migration_interval: usize,
    allocator: std.mem.Allocator,
    seed: u64,

    best_result: Chromosome = undefined,
    best_fitness: f32 = std.math.floatMax(f32),
};
