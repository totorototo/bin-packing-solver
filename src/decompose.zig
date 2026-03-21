//! Convex decomposition of simple polygons via ear-clipping triangulation.
//!
//! A simple polygon is decomposed into triangles (all of which are trivially convex).
//! The decomposition is used by the NFP engine to handle non-convex piece shapes:
//!   NFP(A, B) = union { NFP(Ai, Bj) | Ai ∈ parts(A), Bj ∈ parts(B) }
//! Since we don't need the union as a single polygon — only point-in-union tests —
//! we return a flat list of convex parts and test each one separately.
//!
//! Input: a simple polygon (CCW winding, no self-intersections).
//! Output: a slice of Polygon triangles. Each triangle owns its vertices heap.
//!   The caller must deinit each triangle and free the slice itself.

const std = @import("std");
const Vec2 = @import("vec2.zig").Vec2;
const Polygon = @import("polygon.zig").Polygon;

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

/// Signed area × 2 of triangle (a, b, c).
/// Positive → CCW, negative → CW, zero → degenerate.
fn cross2D(a: Vec2, b: Vec2, c: Vec2) f32 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

/// True if point p lies inside or on the boundary of CCW triangle (a, b, c).
fn pointInTriangle(p: Vec2, a: Vec2, b: Vec2, c: Vec2) bool {
    const d1 = cross2D(a, b, p);
    const d2 = cross2D(b, c, p);
    const d3 = cross2D(c, a, p);
    const has_neg = (d1 < -1e-6) or (d2 < -1e-6) or (d3 < -1e-6);
    const has_pos = (d1 > 1e-6) or (d2 > 1e-6) or (d3 > 1e-6);
    return !(has_neg and has_pos);
}

/// True if vertex at position `idx` in the remaining-vertex list is an ear.
/// An ear is a convex vertex whose triangle contains no other remaining vertex.
fn isEar(all_verts: []const Vec2, remaining: []usize, idx: usize) bool {
    const n = remaining.len;
    if (n < 3) return false;

    const prev = (idx + n - 1) % n;
    const next = (idx + 1) % n;

    const a = all_verts[remaining[prev]];
    const b = all_verts[remaining[idx]];
    const c = all_verts[remaining[next]];

    // Triangle must be CCW (vertex is convex in the polygon).
    if (cross2D(a, b, c) <= 1e-9) return false;

    // No other remaining vertex may lie inside the triangle.
    for (0..n) |i| {
        if (i == prev or i == idx or i == next) continue;
        const p = all_verts[remaining[i]];
        if (pointInTriangle(p, a, b, c)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Free a decomposition produced by `decomposeConvex`.
/// Call this to release all vertex slices and the parts array itself.
pub fn freeParts(allocator: std.mem.Allocator, parts: []Polygon) void {
    for (parts) |*p| p.deinit(allocator);
    allocator.free(parts);
}

/// Decompose `poly` into convex sub-polygons (triangles).
///
/// If `poly` is already convex, returns a single-element slice containing a clone.
/// Otherwise uses ear-clipping triangulation (O(n²)) to produce n−2 triangles.
///
/// The returned slice and each element's `.vertices` are heap-allocated.
/// Release with `freeParts(allocator, result)`.
pub fn decomposeConvex(allocator: std.mem.Allocator, poly: Polygon) ![]Polygon {
    // Fast path: already convex → single clone.
    if (poly.isConvex()) {
        const parts = try allocator.alloc(Polygon, 1);
        errdefer allocator.free(parts);
        parts[0] = try poly.clone(allocator);
        return parts;
    }

    const n = poly.vertices.len;
    if (n < 3) return error.InvalidPolygon;

    // Working list of remaining vertex indices.
    var remaining = try allocator.alloc(usize, n);
    defer allocator.free(remaining);
    for (0..n) |i| remaining[i] = i;
    var rem_n = n;

    // Collect triangle polygons.
    var parts_list = std.ArrayList(Polygon){};
    errdefer {
        for (parts_list.items) |*t| t.deinit(allocator);
        parts_list.deinit(allocator);
    }

    var iters: usize = 0;
    const max_iters = n * n + n;

    while (rem_n > 3 and iters < max_iters) {
        iters += 1;
        var ear_found = false;
        for (0..rem_n) |i| {
            if (!isEar(poly.vertices, remaining[0..rem_n], i)) continue;

            const prev = (i + rem_n - 1) % rem_n;
            const next = (i + 1) % rem_n;

            // Allocate vertices for this triangle.
            const tri_verts = try allocator.alloc(Vec2, 3);
            // If a later step fails, the outer errdefer will deinit already-appended
            // triangles, but NOT this tri_verts (risk is small: only a failed append).
            tri_verts[0] = poly.vertices[remaining[prev]];
            tri_verts[1] = poly.vertices[remaining[i]];
            tri_verts[2] = poly.vertices[remaining[next]];

            var tri = Polygon{ .vertices = tri_verts };
            tri.initBoundingBox();
            try parts_list.append(allocator, tri);

            // Remove vertex i by shifting the remaining array.
            var j = i;
            while (j < rem_n - 1) : (j += 1) remaining[j] = remaining[j + 1];
            rem_n -= 1;

            ear_found = true;
            break;
        }
        if (!ear_found) break; // Degenerate polygon — emit remaining as-is.
    }

    // Final triangle (or degenerate leftover with >= 3 vertices).
    if (rem_n >= 3) {
        const tri_verts = try allocator.alloc(Vec2, 3);
        tri_verts[0] = poly.vertices[remaining[0]];
        tri_verts[1] = poly.vertices[remaining[1]];
        tri_verts[2] = poly.vertices[remaining[2]];
        var tri = Polygon{ .vertices = tri_verts };
        tri.initBoundingBox();
        try parts_list.append(allocator, tri);
    }

    return try parts_list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn makeConvexPoly(allocator: std.mem.Allocator, verts: []const Vec2) !Polygon {
    const v = try allocator.alloc(Vec2, verts.len);
    @memcpy(v, verts);
    var p = Polygon{ .vertices = v };
    p.initBoundingBox();
    return p;
}

test "decomposeConvex - unit square (already convex) returns 1 part" {
    const allocator = std.testing.allocator;
    const sq_verts = [_]Vec2{
        Vec2.init(0, 0), Vec2.init(1, 0), Vec2.init(1, 1), Vec2.init(0, 1),
    };
    var sq = try makeConvexPoly(allocator, &sq_verts);
    defer sq.deinit(allocator);

    const parts = try decomposeConvex(allocator, sq);
    defer freeParts(allocator, parts);

    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), parts[0].area, 0.001);
}

test "decomposeConvex - L-shape (6 vertices) decomposes into 4 triangles" {
    // L-shape (non-convex): 6 vertices
    // (0,0),(2,0),(2,1),(1,1),(1,2),(0,2)
    const allocator = std.testing.allocator;
    const l_verts = [_]Vec2{
        Vec2.init(0, 0), Vec2.init(2, 0), Vec2.init(2, 1),
        Vec2.init(1, 1), Vec2.init(1, 2), Vec2.init(0, 2),
    };
    var l_shape = try makeConvexPoly(allocator, &l_verts);
    defer l_shape.deinit(allocator);

    const parts = try decomposeConvex(allocator, l_shape);
    defer freeParts(allocator, parts);

    // n - 2 = 4 triangles for a 6-vertex polygon.
    try std.testing.expectEqual(@as(usize, 4), parts.len);

    // Total area of triangles must equal area of L-shape = 3.
    var total_area: f32 = 0;
    for (parts) |t| total_area += t.area;
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), total_area, 0.01);
}

test "decomposeConvex - triangle (already convex) returns 1 part" {
    const allocator = std.testing.allocator;
    const tri_verts = [_]Vec2{
        Vec2.init(0, 0), Vec2.init(2, 0), Vec2.init(0, 2),
    };
    var tri = try makeConvexPoly(allocator, &tri_verts);
    defer tri.deinit(allocator);

    const parts = try decomposeConvex(allocator, tri);
    defer freeParts(allocator, parts);

    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), parts[0].area, 0.001);
}

test "decomposeConvex - total area preserved for T-shape" {
    // T-shape (non-convex): 8 vertices, area = 5
    //  (0,0),(3,0),(3,1),(2,1),(2,2),(1,2),(1,1),(0,1)
    const allocator = std.testing.allocator;
    const t_verts = [_]Vec2{
        Vec2.init(0, 0), Vec2.init(3, 0), Vec2.init(3, 1),
        Vec2.init(2, 1), Vec2.init(2, 2), Vec2.init(1, 2),
        Vec2.init(1, 1), Vec2.init(0, 1),
    };
    var t_shape = try makeConvexPoly(allocator, &t_verts);
    defer t_shape.deinit(allocator);

    const t_area = t_shape.calculateArea();
    const parts = try decomposeConvex(allocator, t_shape);
    defer freeParts(allocator, parts);

    var total_area: f32 = 0;
    for (parts) |p| total_area += p.area;
    try std.testing.expectApproxEqAbs(t_area, total_area, 0.01);
}
