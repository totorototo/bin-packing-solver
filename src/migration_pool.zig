const std = @import("std");
const Chromosome = @import("chromosome.zig").Chromosome;

pub const MigrationPool = struct {
    best_solutions: []Chromosome,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_cores: usize, num_pieces: usize) !MigrationPool {
        const solutions = try allocator.alloc(Chromosome, num_cores);
        for (solutions) |*sol| {
            sol.* = try Chromosome.init(allocator, num_pieces);
            sol.fitness = std.math.floatMax(f32);
        }

        return .{
            .best_solutions = solutions,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MigrationPool) void {
        for (self.best_solutions) |*sol| sol.deinit();
        self.allocator.free(self.best_solutions);
    }

    pub fn submitBest(self: *MigrationPool, core_id: usize, solution: Chromosome) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (solution.fitness < self.best_solutions[core_id].fitness) {
            self.best_solutions[core_id].deinit();
            self.best_solutions[core_id] = try solution.clone();
        }
    }

    pub fn importBest(self: *MigrationPool, core_id: usize) !?Chromosome {
        self.mutex.lock();
        defer self.mutex.unlock();

        var best_other_idx: ?usize = null;
        for (self.best_solutions, 0..) |sol, i| {
            if (i == core_id) continue;
            if (best_other_idx == null or sol.fitness < self.best_solutions[best_other_idx.?].fitness) {
                best_other_idx = i;
            }
        }

        if (best_other_idx) |idx| {
            return try self.best_solutions[idx].clone();
        }
        return null;
    }
};

test "MigrationPool init - all slots start at floatMax" {
    const allocator = std.testing.allocator;
    var pool = try MigrationPool.init(allocator, 3, 4);
    defer pool.deinit();

    for (pool.best_solutions) |sol| {
        try std.testing.expectEqual(std.math.floatMax(f32), sol.fitness);
    }
}

test "MigrationPool submitBest - better solution updates slot" {
    const allocator = std.testing.allocator;
    var pool = try MigrationPool.init(allocator, 2, 3);
    defer pool.deinit();

    var candidate = try Chromosome.init(allocator, 3);
    defer candidate.deinit();
    candidate.fitness = 42.0;

    try pool.submitBest(0, candidate);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), pool.best_solutions[0].fitness, 0.001);
}

test "MigrationPool submitBest - worse solution does not replace slot" {
    const allocator = std.testing.allocator;
    var pool = try MigrationPool.init(allocator, 2, 3);
    defer pool.deinit();

    var good = try Chromosome.init(allocator, 3);
    defer good.deinit();
    good.fitness = 10.0;
    try pool.submitBest(0, good);

    var worse = try Chromosome.init(allocator, 3);
    defer worse.deinit();
    worse.fitness = 50.0;
    try pool.submitBest(0, worse);

    try std.testing.expectApproxEqAbs(@as(f32, 10.0), pool.best_solutions[0].fitness, 0.001);
}

test "MigrationPool importBest - returns best from other cores" {
    const allocator = std.testing.allocator;
    var pool = try MigrationPool.init(allocator, 3, 2);
    defer pool.deinit();

    var sol1 = try Chromosome.init(allocator, 2);
    defer sol1.deinit();
    sol1.fitness = 30.0;
    try pool.submitBest(1, sol1);

    var sol2 = try Chromosome.init(allocator, 2);
    defer sol2.deinit();
    sol2.fitness = 20.0;
    try pool.submitBest(2, sol2);

    // Core 0 imports: best of cores 1 and 2 is fitness=20
    var imported = try pool.importBest(0);
    defer if (imported) |*imp| imp.deinit();

    try std.testing.expect(imported != null);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), imported.?.fitness, 0.001);
}

test "MigrationPool importBest - single core returns null" {
    const allocator = std.testing.allocator;
    var pool = try MigrationPool.init(allocator, 1, 2);
    defer pool.deinit();

    const imported = try pool.importBest(0);
    try std.testing.expect(imported == null);
}
