const Vec2 = @import("vec2.zig").Vec2;
const Polygon = @import("polygon.zig").Polygon;

pub const PlacedItem = struct {
    poly: Polygon,
    pos: Vec2,
    rotation: f32,
    piece_id: usize,
};
