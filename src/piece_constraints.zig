const std = @import("std");
const RotationConstraint = @import("rotation_constraints.zig").RotationConstraint;

pub const PieceConstraints = struct {
    /// Grain line angle in radians (from DXF/ASTM)
    grain_angle: f32,
    /// Type of rotation constraint
    rotation_constraint: RotationConstraint,
    /// Precomputed allowed rotation angles based on constraint type
    allowed_rotations: []const f32,

    /// Default: free rotation (all 8 angles)
    pub const default: PieceConstraints = .{
        .grain_angle = 0,
        .rotation_constraint = .free,
        .allowed_rotations = &[_]f32{ 0, 45, 90, 135, 180, 225, 270, 315 },
    };

    /// Create constraints from a grain line angle
    pub fn forGrainLine(grain_angle: f32, constraint: RotationConstraint) PieceConstraints {
        return .{
            .grain_angle = grain_angle,
            .rotation_constraint = constraint,
            .allowed_rotations = switch (constraint) {
                .free => &[_]f32{ 0, 45, 90, 135, 180, 225, 270, 315 },
                .fixed => &[_]f32{0},
                .flip_only => &[_]f32{ 0, 180 },
                .quarter_only => &[_]f32{ 0, 90, 180, 270 },
            },
        };
    }
};

test "PieceConstraints default has 8 free rotations" {
    const pc = PieceConstraints.default;
    try std.testing.expectEqual(RotationConstraint.free, pc.rotation_constraint);
    try std.testing.expectEqual(@as(usize, 8), pc.allowed_rotations.len);
    try std.testing.expectEqual(@as(f32, 0), pc.grain_angle);
}

test "PieceConstraints forGrainLine - fixed allows only 0 degrees" {
    const pc = PieceConstraints.forGrainLine(0, .fixed);
    try std.testing.expectEqual(RotationConstraint.fixed, pc.rotation_constraint);
    try std.testing.expectEqual(@as(usize, 1), pc.allowed_rotations.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pc.allowed_rotations[0], 0.001);
}

test "PieceConstraints forGrainLine - flip_only allows 0 and 180" {
    const pc = PieceConstraints.forGrainLine(0, .flip_only);
    try std.testing.expectEqual(RotationConstraint.flip_only, pc.rotation_constraint);
    try std.testing.expectEqual(@as(usize, 2), pc.allowed_rotations.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pc.allowed_rotations[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 180), pc.allowed_rotations[1], 0.001);
}

test "PieceConstraints forGrainLine - quarter_only allows 4 angles" {
    const pc = PieceConstraints.forGrainLine(0, .quarter_only);
    try std.testing.expectEqual(RotationConstraint.quarter_only, pc.rotation_constraint);
    try std.testing.expectEqual(@as(usize, 4), pc.allowed_rotations.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pc.allowed_rotations[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 90), pc.allowed_rotations[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 180), pc.allowed_rotations[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 270), pc.allowed_rotations[3], 0.001);
}

test "PieceConstraints forGrainLine - free allows 8 angles" {
    const pc = PieceConstraints.forGrainLine(45, .free);
    try std.testing.expectEqual(RotationConstraint.free, pc.rotation_constraint);
    try std.testing.expectEqual(@as(usize, 8), pc.allowed_rotations.len);
    try std.testing.expectApproxEqAbs(@as(f32, 45), pc.grain_angle, 0.001);
}
