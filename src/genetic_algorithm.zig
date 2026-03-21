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
    strip_height: f32,
    grid_resolution: f32,
    allocator: std.mem.Allocator,
    random: std.Random,
    /// Optional per-piece constraints for grain line support
    piece_constraints: ?[]const PieceConstraints = null,

    pub fn init(
        allocator: std.mem.Allocator,
        pieces: []Polygon,
        strip_height: f32,
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
            .strip_height = strip_height,
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
        var packer = Packer.init(self.allocator, self.strip_height, self.grid_resolution);
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
        chromo.fitness = packer.getMaxWidth();
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
