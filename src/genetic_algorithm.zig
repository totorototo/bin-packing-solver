const std = @import("std");
const Chromosome = @import("chromosome.zig").Chromosome;
const Polygon = @import("polygon.zig").Polygon;
const Packer = @import("packer.zig").Packer;
const PieceConstraints = @import("piece_constraints.zig").PieceConstraints;

pub const GeneticAlgorithm = struct {
    population_size: usize,
    elite_size: usize,
    mutant_size: usize,
    population: []Chromosome,
    pieces: []Polygon,
    rotation_angles: []const f32,
    strip_width: f32,
    grid_resolution: f32,
    allocator: std.mem.Allocator,
    random: std.Random,
    /// Optional per-piece constraints for grain line support
    piece_constraints: ?[]const PieceConstraints = null,

    pub fn init(
        allocator: std.mem.Allocator,
        pieces: []Polygon,
        strip_width: f32,
        grid_resolution: f32,
        pop_size: usize,
        elite_sz: usize,
        mutant_sz: usize,
        rand: std.Random,
        piece_constraints: ?[]const PieceConstraints,
    ) !GeneticAlgorithm {
        const pop = try allocator.alloc(Chromosome, pop_size);
        for (pop) |*chromo| {
            chromo.* = try Chromosome.init(allocator, pieces.len);
            chromo.piece_constraints = piece_constraints;
        }

        return .{
            .population_size = pop_size,
            .elite_size = elite_sz,
            .mutant_size = mutant_sz,
            .population = pop,
            .pieces = pieces,
            .rotation_angles = &[_]f32{ 0, 45, 90, 135, 180, 225, 270, 315 },
            .strip_width = strip_width,
            .grid_resolution = grid_resolution,
            .allocator = allocator,
            .random = rand,
            .piece_constraints = piece_constraints,
        };
    }

    pub fn deinit(self: *GeneticAlgorithm) void {
        for (self.population) |*chromo| {
            chromo.deinit();
        }
        self.allocator.free(self.population);
    }

    pub fn initializePopulation(self: *GeneticAlgorithm) void {
        for (self.population) |*chromo| {
            chromo.randomize(self.random, self.rotation_angles);
        }
    }

    pub fn evaluateFitness(self: *GeneticAlgorithm, chromo: *Chromosome) !void {
        var packer = Packer.init(self.allocator, self.strip_width, self.grid_resolution);
        defer packer.deinit();

        for (chromo.sequence) |piece_idx| {
            const orig_poly = self.pieces[piece_idx];
            var rotated = try orig_poly.rotateByAngle(self.allocator, chromo.rotations[piece_idx]);
            defer rotated.deinit(self.allocator);

            if (try packer.placePolygon(rotated, piece_idx, chromo.rotations[piece_idx])) |placement| {
                try packer.placed_items.append(self.allocator, placement);
            } else {
                chromo.placement_failed = true;
                chromo.fitness = std.math.floatMax(f32);
                return;
            }
        }
        chromo.placement_failed = false;
        chromo.fitness = packer.getLength();
    }

    pub fn evaluateAll(self: *GeneticAlgorithm) !void {
        for (self.population) |*chromo| {
            try self.evaluateFitness(chromo);
        }
    }

    pub fn crossover(self: *GeneticAlgorithm, parent1: Chromosome, parent2: Chromosome) !Chromosome {
        var child = try Chromosome.init(self.allocator, parent1.sequence.len);
        child.piece_constraints = self.piece_constraints;

        const cut1 = self.random.intRangeLessThan(usize, 0, parent1.sequence.len);
        const cut2 = self.random.intRangeLessThan(usize, cut1, parent1.sequence.len);

        var used = try self.allocator.alloc(bool, parent1.sequence.len);
        defer self.allocator.free(used);
        @memset(used, false);

        for (cut1..cut2) |i| {
            child.sequence[i] = parent1.sequence[i];
            used[parent1.sequence[i]] = true;
        }

        var child_idx: usize = 0;
        for (parent2.sequence) |gene| {
            if (!used[gene]) {
                if (child_idx == cut1) child_idx = cut2;
                if (child_idx >= child.sequence.len) break;
                child.sequence[child_idx] = gene;
                child_idx += 1;
            }
        }

        for (0..child.rotations.len) |i| {
            child.rotations[i] = if (self.random.boolean()) parent1.rotations[i] else parent2.rotations[i];
        }

        return child;
    }

    /// Mutate chromosome respecting per-piece rotation constraints
    pub fn mutate(self: *GeneticAlgorithm, chromo: *Chromosome, mutation_rate: f32) void {
        if (self.random.float(f32) < mutation_rate) {
            const i = self.random.intRangeLessThan(usize, 0, chromo.sequence.len);
            const j = self.random.intRangeLessThan(usize, 0, chromo.sequence.len);
            const tmp = chromo.sequence[i];
            chromo.sequence[i] = chromo.sequence[j];
            chromo.sequence[j] = tmp;
        }

        for (chromo.rotations, 0..) |*r, i| {
            if (self.random.float(f32) < mutation_rate) {
                // Use per-piece constraints if available
                const allowed = if (self.piece_constraints) |pc| pc[i].allowed_rotations else self.rotation_angles;
                r.* = allowed[self.random.intRangeLessThan(usize, 0, allowed.len)];
            }
        }
    }

    /// Single generation evolution step
    pub fn evolveOneGeneration(self: *GeneticAlgorithm) !void {
        var new_population = try self.allocator.alloc(Chromosome, self.population_size);

        std.mem.sort(Chromosome, self.population, {}, struct {
            fn lessThan(_: void, a: Chromosome, b: Chromosome) bool {
                return a.fitness < b.fitness;
            }
        }.lessThan);

        // Elitism
        for (0..self.elite_size) |i| {
            new_population[i] = try self.population[i].clone();
        }

        // Mutants
        for (self.elite_size..self.elite_size + self.mutant_size) |i| {
            var mutant = try Chromosome.init(self.allocator, self.pieces.len);
            mutant.piece_constraints = self.piece_constraints;
            mutant.randomize(self.random, self.rotation_angles);
            new_population[i] = mutant;
        }

        // Crossover
        for (self.elite_size + self.mutant_size..self.population_size) |i| {
            const elite_idx = self.random.intRangeLessThan(usize, 0, self.elite_size);
            const rest_idx = self.random.intRangeLessThan(usize, self.elite_size, self.population_size);

            const parent1 = self.population[elite_idx];
            const parent2 = self.population[rest_idx];

            var child = try self.crossover(parent1, parent2);
            self.mutate(&child, 0.05);
            new_population[i] = child;
        }

        for (self.population) |*chromo| {
            chromo.deinit();
        }
        self.allocator.free(self.population);
        self.population = new_population;

        try self.evaluateAll();
    }
};

fn makeTestSquare(allocator: std.mem.Allocator, size: f32) !Polygon {
    const Vec2 = @import("vec2.zig").Vec2;
    const v = try allocator.alloc(Vec2, 4);
    v[0] = .{ .x = 0, .y = 0 };
    v[1] = .{ .x = size, .y = 0 };
    v[2] = .{ .x = size, .y = size };
    v[3] = .{ .x = 0, .y = size };
    var p = Polygon{ .vertices = v };
    p.initBoundingBox();
    return p;
}

test "GeneticAlgorithm init - population size and chromosome length" {
    const allocator = std.testing.allocator;
    var sq = try makeTestSquare(allocator, 3);
    defer sq.deinit(allocator);
    var pieces = [_]Polygon{sq};

    var prng = std.Random.DefaultPrng.init(0);
    var ga = try GeneticAlgorithm.init(allocator, &pieces, 10.0, 1.0, 8, 2, 2, prng.random(), null);
    defer ga.deinit();

    try std.testing.expectEqual(@as(usize, 8), ga.population.len);
    for (ga.population) |chromo| {
        try std.testing.expectEqual(@as(usize, 1), chromo.sequence.len);
    }
}

test "GeneticAlgorithm initializePopulation - chromosomes are valid permutations" {
    const allocator = std.testing.allocator;
    var squares: [3]Polygon = undefined;
    for (0..3) |i| squares[i] = try makeTestSquare(allocator, @as(f32, @floatFromInt(i + 1)));
    defer for (&squares) |*s| s.deinit(allocator);

    var prng = std.Random.DefaultPrng.init(42);
    var ga = try GeneticAlgorithm.init(allocator, &squares, 20.0, 1.0, 6, 2, 1, prng.random(), null);
    defer ga.deinit();
    ga.initializePopulation();

    for (ga.population) |chromo| {
        var seen = [_]bool{false} ** 3;
        for (chromo.sequence) |idx| {
            try std.testing.expect(idx < 3);
            try std.testing.expect(!seen[idx]);
            seen[idx] = true;
        }
    }
}

test "GeneticAlgorithm evaluateFitness - valid placement sets finite fitness" {
    const allocator = std.testing.allocator;
    var sq = try makeTestSquare(allocator, 3);
    defer sq.deinit(allocator);
    var pieces = [_]Polygon{sq};

    var prng = std.Random.DefaultPrng.init(0);
    var ga = try GeneticAlgorithm.init(allocator, &pieces, 10.0, 1.0, 2, 1, 1, prng.random(), null);
    defer ga.deinit();

    var chromo = &ga.population[0];
    chromo.sequence[0] = 0;
    chromo.rotations[0] = 0;
    try ga.evaluateFitness(chromo);

    try std.testing.expect(!chromo.placement_failed);
    try std.testing.expect(chromo.fitness < std.math.floatMax(f32));
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), chromo.fitness, 0.1);
}

test "GeneticAlgorithm evaluateFitness - unplaceable piece sets floatMax" {
    const allocator = std.testing.allocator;
    // height=8 > strip_width=5 → can never be placed
    var sq = try makeTestSquare(allocator, 8);
    defer sq.deinit(allocator);
    var pieces = [_]Polygon{sq};

    var prng = std.Random.DefaultPrng.init(0);
    var ga = try GeneticAlgorithm.init(allocator, &pieces, 5.0, 1.0, 2, 1, 1, prng.random(), null);
    defer ga.deinit();

    var chromo = &ga.population[0];
    chromo.sequence[0] = 0;
    chromo.rotations[0] = 0;
    try ga.evaluateFitness(chromo);

    try std.testing.expect(chromo.placement_failed);
    try std.testing.expectEqual(std.math.floatMax(f32), chromo.fitness);
}

test "GeneticAlgorithm crossover - child is a valid permutation" {
    const allocator = std.testing.allocator;
    var squares: [5]Polygon = undefined;
    for (0..5) |i| squares[i] = try makeTestSquare(allocator, 2);
    defer for (&squares) |*s| s.deinit(allocator);

    var prng = std.Random.DefaultPrng.init(7);
    var ga = try GeneticAlgorithm.init(allocator, &squares, 20.0, 1.0, 4, 2, 1, prng.random(), null);
    defer ga.deinit();
    ga.initializePopulation();

    var child = try ga.crossover(ga.population[0], ga.population[1]);
    defer child.deinit();

    try std.testing.expectEqual(@as(usize, 5), child.sequence.len);
    var seen = [_]bool{false} ** 5;
    for (child.sequence) |idx| {
        try std.testing.expect(idx < 5);
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }
}

test "GeneticAlgorithm mutate - sequence remains a valid permutation" {
    const allocator = std.testing.allocator;
    var squares: [4]Polygon = undefined;
    for (0..4) |i| squares[i] = try makeTestSquare(allocator, 2);
    defer for (&squares) |*s| s.deinit(allocator);

    var prng = std.Random.DefaultPrng.init(1);
    var ga = try GeneticAlgorithm.init(allocator, &squares, 20.0, 1.0, 2, 1, 1, prng.random(), null);
    defer ga.deinit();
    ga.initializePopulation();

    // mutation_rate=1.0 guarantees a swap occurs
    ga.mutate(&ga.population[0], 1.0);

    var seen = [_]bool{false} ** 4;
    for (ga.population[0].sequence) |idx| {
        try std.testing.expect(idx < 4);
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }
}

test "GeneticAlgorithm evolveOneGeneration - population size unchanged" {
    const allocator = std.testing.allocator;
    var squares: [2]Polygon = undefined;
    for (0..2) |i| squares[i] = try makeTestSquare(allocator, 2);
    defer for (&squares) |*s| s.deinit(allocator);

    var prng = std.Random.DefaultPrng.init(42);
    var ga = try GeneticAlgorithm.init(allocator, &squares, 10.0, 1.0, 6, 2, 1, prng.random(), null);
    defer ga.deinit();

    ga.initializePopulation();
    try ga.evaluateAll();
    try ga.evolveOneGeneration();

    try std.testing.expectEqual(@as(usize, 6), ga.population.len);
}
