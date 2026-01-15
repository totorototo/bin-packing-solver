const std = @import("std");
const PieceConstraints = @import("piece_constraints.zig").PieceConstraints;

pub const Chromosome = struct {
    sequence: []usize,
    rotations: []f32,
    fitness: f32 = std.math.floatMax(f32),
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
            .allocator = self.allocator,
            .piece_constraints = self.piece_constraints,
        };
    }

    pub fn deinit(self: *Chromosome) void {
        self.allocator.free(self.sequence);
        self.allocator.free(self.rotations);
    }
};
