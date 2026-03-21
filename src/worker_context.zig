const std = @import("std");
const Chromosome = @import("chromosome.zig").Chromosome;
const Polygon = @import("polygon.zig").Polygon;
const PieceConstraints = @import("piece_constraints.zig").PieceConstraints;
const MigrationPool = @import("migration_pool.zig").MigrationPool;

pub const WorkerContext = struct {
    core_id: usize,
    pieces: []Polygon,
    piece_constraints: ?[]const PieceConstraints = null,
    strip_width: f32,
    population_size: usize,
    elite_size: usize,
    mutant_size: usize,
    generations: usize,
    migration_pool: *MigrationPool,
    migration_interval: usize,
    grid_resolution: f32,
    stagnation_limit: usize,
    allocator: std.mem.Allocator,
    seed: u64,
    verbose: bool = false,
    use_nfp: bool = false,
    mutation_rate: f32 = 0.05,
    /// Absolute deadline in milliseconds (from std.time.milliTimestamp). Null = no timeout.
    timeout_end_ms: ?i64 = null,

    best_result: ?Chromosome = null,
    best_fitness: f32 = std.math.floatMax(f32),
};
