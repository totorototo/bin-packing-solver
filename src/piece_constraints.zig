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
