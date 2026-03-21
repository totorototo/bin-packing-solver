const std = @import("std");
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

fn makeSquare(allocator: std.mem.Allocator, x: f32, y: f32, size: f32) !Polygon {
    const verts = try allocator.alloc(Vec2, 4);
    verts[0] = Vec2.init(x, y);
    verts[1] = Vec2.init(x + size, y);
    verts[2] = Vec2.init(x + size, y + size);
    verts[3] = Vec2.init(x, y + size);
    var p = Polygon{ .vertices = verts };
    p.initBoundingBox();
    return p;
}

test "SAT - overlapping squares" {
    const allocator = std.testing.allocator;
    var a = try makeSquare(allocator, 0, 0, 2);
    defer a.deinit(allocator);
    var b = try makeSquare(allocator, 0, 0, 2);
    defer b.deinit(allocator);
    try std.testing.expect(isOverlappingSAT(a, Vec2.init(0, 0), b, Vec2.init(1, 0)));
}

test "SAT - separated squares do not overlap" {
    const allocator = std.testing.allocator;
    var a = try makeSquare(allocator, 0, 0, 2);
    defer a.deinit(allocator);
    var b = try makeSquare(allocator, 0, 0, 2);
    defer b.deinit(allocator);
    try std.testing.expect(!isOverlappingSAT(a, Vec2.init(0, 0), b, Vec2.init(3, 0)));
}

test "SAT - touching edges are considered overlapping" {
    const allocator = std.testing.allocator;
    var a = try makeSquare(allocator, 0, 0, 2);
    defer a.deinit(allocator);
    var b = try makeSquare(allocator, 0, 0, 2);
    defer b.deinit(allocator);
    // SAT uses strict < so touching projections (max == min) are not separating axes
    try std.testing.expect(isOverlappingSAT(a, Vec2.init(0, 0), b, Vec2.init(2, 0)));
}

fn makeTriangle(allocator: std.mem.Allocator, x: f32, y: f32, size: f32) !Polygon {
    // Right triangle: (x,y), (x+size,y), (x,y+size)
    const verts = try allocator.alloc(Vec2, 3);
    verts[0] = Vec2.init(x, y);
    verts[1] = Vec2.init(x + size, y);
    verts[2] = Vec2.init(x, y + size);
    var p = Polygon{ .vertices = verts };
    p.initBoundingBox();
    return p;
}

test "SAT - overlapping triangles" {
    const allocator = std.testing.allocator;
    var a = try makeTriangle(allocator, 0, 0, 4);
    defer a.deinit(allocator);
    var b = try makeTriangle(allocator, 0, 0, 4);
    defer b.deinit(allocator);
    try std.testing.expect(isOverlappingSAT(a, Vec2.init(0, 0), b, Vec2.init(1, 0)));
}

test "SAT - separated triangles do not overlap" {
    const allocator = std.testing.allocator;
    var a = try makeTriangle(allocator, 0, 0, 2);
    defer a.deinit(allocator);
    var b = try makeTriangle(allocator, 0, 0, 2);
    defer b.deinit(allocator);
    // Place b well to the right so there's a clear gap
    try std.testing.expect(!isOverlappingSAT(a, Vec2.init(0, 0), b, Vec2.init(5, 0)));
}

test "SAT - triangle and square overlapping" {
    const allocator = std.testing.allocator;
    var tri = try makeTriangle(allocator, 0, 0, 3);
    defer tri.deinit(allocator);
    var sq = try makeSquare(allocator, 0, 0, 3);
    defer sq.deinit(allocator);
    try std.testing.expect(isOverlappingSAT(tri, Vec2.init(0, 0), sq, Vec2.init(1, 0)));
}

test "SAT - triangle and square separated" {
    const allocator = std.testing.allocator;
    var tri = try makeTriangle(allocator, 0, 0, 2);
    defer tri.deinit(allocator);
    var sq = try makeSquare(allocator, 0, 0, 2);
    defer sq.deinit(allocator);
    try std.testing.expect(!isOverlappingSAT(tri, Vec2.init(0, 0), sq, Vec2.init(10, 0)));
}

test "SAT getProjection - axis-aligned square projects correctly" {
    const allocator = std.testing.allocator;
    var sq = try makeSquare(allocator, 0, 0, 2);
    defer sq.deinit(allocator);
    const x_axis = Vec2.init(1, 0);
    const proj = getProjection(sq, Vec2.init(0, 0), x_axis);
    try std.testing.expectApproxEqAbs(@as(f32, 0), proj.min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), proj.max, 0.001);
}

test "SAT getProjection - offset position shifts projection" {
    const allocator = std.testing.allocator;
    var sq = try makeSquare(allocator, 0, 0, 2);
    defer sq.deinit(allocator);
    const x_axis = Vec2.init(1, 0);
    const proj = getProjection(sq, Vec2.init(3, 0), x_axis);
    try std.testing.expectApproxEqAbs(@as(f32, 3), proj.min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), proj.max, 0.001);
}
