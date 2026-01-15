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
