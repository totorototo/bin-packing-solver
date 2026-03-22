const std = @import("std");
const Vec2 = @import("vec2.zig").Vec2;
const Polygon = @import("polygon.zig").Polygon;

/// Graham scan convex hull — O(n log n). Returns a newly allocated CCW slice of hull vertices.
fn convexHull(allocator: std.mem.Allocator, points: []const Vec2) ![]Vec2 {
    if (points.len < 3) return allocator.dupe(Vec2, points);

    // Find pivot: bottommost (min y), then leftmost (min x).
    var pivot_idx: usize = 0;
    for (points, 0..) |p, i| {
        if (p.y < points[pivot_idx].y or
            (p.y == points[pivot_idx].y and p.x < points[pivot_idx].x))
            pivot_idx = i;
    }
    const pivot = points[pivot_idx];

    // Copy points and move pivot to index 0.
    const sorted = try allocator.dupe(Vec2, points);
    defer allocator.free(sorted);
    sorted[pivot_idx] = sorted[0];
    sorted[0] = pivot;

    // Sort remaining points by CCW polar angle from pivot; closer first for ties.
    std.mem.sort(Vec2, sorted[1..], pivot, struct {
        fn lt(p: Vec2, a: Vec2, b: Vec2) bool {
            const cross = (a.x - p.x) * (b.y - p.y) - (a.y - p.y) * (b.x - p.x);
            if (cross > 1e-9) return true;
            if (cross < -1e-9) return false;
            const da = (a.x - p.x) * (a.x - p.x) + (a.y - p.y) * (a.y - p.y);
            const db = (b.x - p.x) * (b.x - p.x) + (b.y - p.y) * (b.y - p.y);
            return da < db;
        }
    }.lt);

    // Graham scan: build CCW hull, popping collinear or right-turning vertices.
    const hull = try allocator.alloc(Vec2, points.len);
    var h: usize = 0;
    for (sorted) |p| {
        while (h >= 2) {
            const cross = (hull[h - 1].x - hull[h - 2].x) * (p.y - hull[h - 2].y) -
                (hull[h - 1].y - hull[h - 2].y) * (p.x - hull[h - 2].x);
            if (cross > 1e-9) break; // strictly left turn — keep
            h -= 1;
        }
        hull[h] = p;
        h += 1;
    }

    const result = try allocator.alloc(Vec2, h);
    @memcpy(result, hull[0..h]);
    allocator.free(hull);
    return result;
}

pub fn generateRandomConvex(allocator: std.mem.Allocator, rand: std.Random, size: f32) !Polygon {
    const num_points = rand.intRangeAtMost(usize, 6, 18);
    var angles = try allocator.alloc(f32, num_points);
    defer allocator.free(angles);

    for (0..num_points) |i| {
        angles[i] = rand.float(f32) * std.math.pi * 2.0;
    }
    std.mem.sort(f32, angles, {}, std.sort.asc(f32));

    var raw_verts = try allocator.alloc(Vec2, num_points);
    defer allocator.free(raw_verts);
    for (0..num_points) |i| {
        const r = size * (0.5 + rand.float(f32) * 0.5);
        raw_verts[i] = Vec2.init(@cos(angles[i]) * r, @sin(angles[i]) * r);
    }

    const hull_verts = try convexHull(allocator, raw_verts);
    var p = Polygon{ .vertices = hull_verts };
    p.normalizeToPositive();
    p.initBoundingBox();
    return p;
}

/// Generate a random concave (simple, non-convex) polygon.
///
/// Starts from a random convex polygon, picks a random edge, and inserts a
/// vertex shifted inward toward the centroid — creating one reflex angle.
/// The returned polygon is heap-allocated; free with `poly.deinit(allocator)`.
pub fn generateRandomConcave(allocator: std.mem.Allocator, rand: std.Random, size: f32) !Polygon {
    var base = try generateRandomConvex(allocator, rand, size);
    defer base.deinit(allocator);

    const n = base.vertices.len;
    const edge_idx = rand.uintLessThan(usize, n);
    const a = base.vertices[edge_idx];
    const b = base.vertices[(edge_idx + 1) % n];

    // Midpoint of edge, shifted toward centroid (30–70 % of the way).
    const mx = (a.x + b.x) * 0.5;
    const my = (a.y + b.y) * 0.5;
    const t = 0.3 + rand.float(f32) * 0.4;
    const notch = Vec2.init(
        mx + t * (base.centroid.x - mx),
        my + t * (base.centroid.y - my),
    );

    // Build new vertex list: insert notch after edge_idx.
    const new_verts = try allocator.alloc(Vec2, n + 1);
    @memcpy(new_verts[0 .. edge_idx + 1], base.vertices[0 .. edge_idx + 1]);
    new_verts[edge_idx + 1] = notch;
    @memcpy(new_verts[edge_idx + 2 ..], base.vertices[edge_idx + 1 ..]);

    var poly = Polygon{ .vertices = new_verts };
    poly.normalizeToPositive();
    poly.initBoundingBox();
    return poly;
}

test "generateRandomConcave - result is concave with positive area" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(789);

    for (0..5) |_| {
        var poly = try generateRandomConcave(allocator, prng.random(), 10.0);
        defer poly.deinit(allocator);

        try std.testing.expect(!poly.isConvex());
        try std.testing.expect(poly.area > 0);
        try std.testing.expect(poly.vertices.len >= 4);
    }
}

test "generateRandomConvex - result is convex with positive area" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(123);

    var poly = try generateRandomConvex(allocator, prng.random(), 10.0);
    defer poly.deinit(allocator);

    try std.testing.expect(poly.isConvex());
    try std.testing.expect(poly.area > 0);
    try std.testing.expect(poly.vertices.len >= 3);
}

test "generateRandomConvex - vertices normalized to non-negative coords" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(456);

    for (0..5) |_| {
        var poly = try generateRandomConvex(allocator, prng.random(), 8.0);
        defer poly.deinit(allocator);
        for (poly.vertices) |v| {
            try std.testing.expect(v.x >= -0.001);
            try std.testing.expect(v.y >= -0.001);
        }
    }
}

