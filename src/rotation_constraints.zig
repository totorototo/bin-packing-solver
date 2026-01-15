pub const RotationConstraint = enum {
    /// All 8 standard rotations allowed (0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°)
    free,
    /// No rotation allowed - piece must stay at original orientation
    fixed,
    /// Only 0° and 180° allowed - respects grain line direction (droit-fil)
    flip_only,
    /// Only 0°, 90°, 180°, 270° allowed - quarter rotations
    quarter_only,
};
