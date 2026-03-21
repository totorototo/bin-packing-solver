const std = @import("std");
const PieceConstraints = @import("piece_constraints.zig").PieceConstraints;

pub const Chromosome = struct {
    sequence: []usize,
    rotations: []f32,
    fitness: f32 = std.math.floatMax(f32),
    /// True when at least one piece could not be placed during evaluation.
    placement_failed: bool = false,
    allocator: std.mem.Allocator,
    /// Optional per-piece constraints (shared reference, not owned)
    piece_constraints: ?[]const PieceConstraints = null,

    pub fn init(allocator: std.mem.Allocator, num_pieces: usize) !Chromosome {
        const seq = try allocator.alloc(usize, num_pieces);
        const rots = try allocator.alloc(f32, num_pieces);
        for (0..num_pieces) |i| {
            seq[i] = i;
            rots[i] = 0;
        }
        return .{
            .sequence = seq,
            .rotations = rots,
            .allocator = allocator,
        };
    }

    /// Randomize chromosome respecting per-piece rotation constraints
    pub fn randomize(self: *Chromosome, rand: std.Random, default_angles: []const f32) void {
        // Shuffle sequence
        for (0..self.sequence.len) |i| {
            const j = rand.intRangeLessThan(usize, i, self.sequence.len);
            const tmp = self.sequence[i];
            self.sequence[i] = self.sequence[j];
            self.sequence[j] = tmp;
        }
        // Assign rotations respecting constraints
        for (self.rotations, 0..) |*r, i| {
            const allowed = if (self.piece_constraints) |pc| pc[i].allowed_rotations else default_angles;
            r.* = allowed[rand.intRangeLessThan(usize, 0, allowed.len)];
        }
    }

    pub fn clone(self: Chromosome) !Chromosome {
        const new_seq = try self.allocator.alloc(usize, self.sequence.len);
        const new_rots = try self.allocator.alloc(f32, self.rotations.len);
        @memcpy(new_seq, self.sequence);
        @memcpy(new_rots, self.rotations);
        return .{
            .sequence = new_seq,
            .rotations = new_rots,
            .fitness = self.fitness,
            .placement_failed = self.placement_failed,
            .allocator = self.allocator,
            .piece_constraints = self.piece_constraints,
        };
    }

    pub fn deinit(self: *Chromosome) void {
        self.allocator.free(self.sequence);
        self.allocator.free(self.rotations);
    }
};

test "Chromosome init - default sequence and rotations" {
    const allocator = std.testing.allocator;
    var c = try Chromosome.init(allocator, 5);
    defer c.deinit();

    try std.testing.expectEqual(@as(usize, 5), c.sequence.len);
    try std.testing.expectEqual(@as(usize, 5), c.rotations.len);
    for (0..5) |i| {
        try std.testing.expectEqual(i, c.sequence[i]);
        try std.testing.expectApproxEqAbs(@as(f32, 0), c.rotations[i], 0.001);
    }
    try std.testing.expectEqual(std.math.floatMax(f32), c.fitness);
    try std.testing.expect(!c.placement_failed);
}

test "Chromosome randomize - sequence is a permutation" {
    const allocator = std.testing.allocator;
    var c = try Chromosome.init(allocator, 6);
    defer c.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    const default_angles = [_]f32{ 0, 90, 180, 270 };
    c.randomize(prng.random(), &default_angles);

    // Must still contain each index exactly once
    var seen = [_]bool{false} ** 6;
    for (c.sequence) |idx| {
        try std.testing.expect(idx < 6);
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }

    // All rotations must be from the allowed set
    for (c.rotations) |r| {
        var found = false;
        for (default_angles) |a| {
            if (@abs(r - a) < 0.001) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "Chromosome randomize - respects piece_constraints" {
    const allocator = std.testing.allocator;

    var c = try Chromosome.init(allocator, 3);
    defer c.deinit();

    // All pieces fixed: only rotation 0 allowed
    const constraints = [_]PieceConstraints{
        PieceConstraints.forGrainLine(0, .fixed),
        PieceConstraints.forGrainLine(0, .fixed),
        PieceConstraints.forGrainLine(0, .fixed),
    };
    c.piece_constraints = &constraints;

    var prng = std.Random.DefaultPrng.init(99);
    const default_angles = [_]f32{ 0, 90, 180, 270 };
    c.randomize(prng.random(), &default_angles);

    for (c.rotations) |r| {
        try std.testing.expectApproxEqAbs(@as(f32, 0), r, 0.001);
    }
}

test "Chromosome clone - independent copy" {
    const allocator = std.testing.allocator;
    var orig = try Chromosome.init(allocator, 4);
    defer orig.deinit();

    orig.fitness = 42.0;
    orig.sequence[0] = 3;
    orig.rotations[1] = 90;

    var copy = try orig.clone();
    defer copy.deinit();

    try std.testing.expectEqual(@as(f32, 42.0), copy.fitness);
    try std.testing.expectEqual(@as(usize, 3), copy.sequence[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 90), copy.rotations[1], 0.001);

    // Mutating original must not affect clone
    orig.sequence[0] = 99;
    try std.testing.expectEqual(@as(usize, 3), copy.sequence[0]);
}
