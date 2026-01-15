const Polygon = @import("polygon.zig").Polygon;
const Vec2 = @import("vec2.zig").Vec2;

pub fn getProjection(poly: Polygon, pos: Vec2, axis: Vec2) struct { min: f32, max: f32 } {
    var min = (poly.vertices[0].x + pos.x) * axis.x + (poly.vertices[0].y + pos.y) * axis.y;
    var max = min;
    for (poly.vertices[1..]) |v| {
        const p = (v.x + pos.x) * axis.x + (v.y + pos.y) * axis.y;
        min = @min(min, p);
        max = @max(max, p);
    }
    return .{ .min = min, .max = max };
}

pub fn isOverlappingSAT(polyA: Polygon, posA: Vec2, polyB: Polygon, posB: Vec2) bool {
    const polys = [2]struct { p: Polygon, pos: Vec2 }{
        .{ .p = polyA, .pos = posA },
        .{ .p = polyB, .pos = posB },
    };
    for (polys) |current| {
        for (0..current.p.vertices.len) |i| {
            const next_i = (i + 1) % current.p.vertices.len;
            const edge = current.p.vertices[next_i].sub(current.p.vertices[i]);
            const axis = edge.perp().normalize();
            const projA = getProjection(polyA, posA, axis);
            const projB = getProjection(polyB, posB, axis);
            if (projA.max < projB.min or projB.max < projA.min) return false;
        }
    }
    return true;
}
