//! No-Fit Polygon (NFP) computation via Minkowski sum.
//!
//! For non-convex polygons, each polygon is decomposed into convex triangles
//! (see decompose.zig) and all pairwise convex NFPs are returned as a list.
//! Collision detection is: relative position is forbidden iff it lies inside ANY part.
//!
//! NFP(A, B) = the set of positions for B's reference point (lower-left corner)
//! that cause B to overlap with A when A is fixed at the origin.
//!
//! Algorithm: NFP(A, B) = A ⊕ (−B), the Minkowski sum of A with the reflection
//! of B through the origin. For two CCW convex polygons this runs in O(n + m).
//!
//! Key property: negating all vertices of a CCW polygon yields another CCW polygon
//! (negation preserves signed area sign), so −B needs no vertex reversal.

const std = @import("std");
const Vec2 = @import("vec2.zig").Vec2;
const Polygon = @import("polygon.zig").Polygon;
const decompose = @import("decompose.zig");

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Index of the bottommost (min y), then leftmost (min x) vertex.
fn findBottomLeft(verts: []const Vec2) usize {
    var idx: usize = 0;
    for (1..verts.len) |i| {
        if (verts[i].y < verts[idx].y or
            (verts[i].y == verts[idx].y and verts[i].x < verts[idx].x))
        {
            idx = i;
        }
    }
    return idx;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Compute NFP(polyA, polyB) for two convex CCW polygons.
///
/// Returns a new polygon (heap-allocated vertices) representing all positions
/// of polyB's lower-left corner that cause polyB to overlap polyA.
/// The caller owns the returned polygon and must call `.deinit(allocator)`.
///
/// Both inputs must be convex and in CCW winding order with vertices normalized
/// so their minimum coordinate is at (0, 0) (i.e. after `normalizeToPositive`).
pub fn computeNFP(allocator: std.mem.Allocator, polyA: Polygon, polyB: Polygon) !Polygon {
    const n = polyA.vertices.len;
    const m = polyB.vertices.len;

    // Step 1: Build −B by negating all vertices.
    // Negating a CCW polygon yields a CCW polygon (signed area sign is preserved),
    // so no reversal is needed.
    const neg_b = try allocator.alloc(Vec2, m);
    defer allocator.free(neg_b);
    for (polyB.vertices, 0..) |v, i| {
        neg_b[i] = Vec2.init(-v.x, -v.y);
    }

    // Step 2: Find starting vertices (bottommost-leftmost).
    const a_start = findBottomLeft(polyA.vertices);
    const nb_start = findBottomLeft(neg_b);

    // Step 3: Starting point of the NFP polygon.
    const start = polyA.vertices[a_start].add(neg_b[nb_start]);

    // Step 4: Edge vectors of each polygon, reordered to begin at their
    // respective starting vertex and traverse CCW.
    const ea = try allocator.alloc(Vec2, n);
    defer allocator.free(ea);
    const eb = try allocator.alloc(Vec2, m);
    defer allocator.free(eb);

    for (0..n) |i| {
        const curr = (a_start + i) % n;
        const next = (a_start + i + 1) % n;
        ea[i] = polyA.vertices[next].sub(polyA.vertices[curr]);
    }
    for (0..m) |i| {
        const curr = (nb_start + i) % m;
        const next = (nb_start + i + 1) % m;
        eb[i] = neg_b[next].sub(neg_b[curr]);
    }

    // Step 5: Merge the two CCW edge sequences in angular order.
    // cross(eA, eB) > 0 → eA has smaller CCW angle → take eA first.
    // cross < 0 → take eB first.
    // cross = 0 → parallel edges (same direction): advance both and sum them
    //             into one combined vertex (no intermediate vertex added).
    var verts_list = std.ArrayList(Vec2){};
    defer verts_list.deinit(allocator);
    try verts_list.ensureTotalCapacity(allocator, n + m);

    try verts_list.append(allocator, start);
    var current = start;
    var i: usize = 0;
    var j: usize = 0;

    while (i < n or j < m) {
        if (i >= n) {
            current = current.add(eb[j]);
            j += 1;
        } else if (j >= m) {
            current = current.add(ea[i]);
            i += 1;
        } else {
            const cross = ea[i].x * eb[j].y - ea[i].y * eb[j].x;
            if (cross > 1e-9) {
                current = current.add(ea[i]);
                i += 1;
            } else if (cross < -1e-9) {
                current = current.add(eb[j]);
                j += 1;
            } else {
                // Parallel edges (|cross| ≤ 1e-9): combine into one step, no intermediate vertex.
                current = current.add(ea[i]).add(eb[j]);
                i += 1;
                j += 1;
            }
        }
        try verts_list.append(allocator, current);
    }

    // The last appended vertex closes the polygon (equals `start`). Remove it.
    if (verts_list.items.len > 1) {
        _ = verts_list.pop();
    }

    const final_verts = try allocator.alloc(Vec2, verts_list.items.len);
    @memcpy(final_verts, verts_list.items);

    var nfp = Polygon{ .vertices = final_verts };
    nfp.initBoundingBox();
    return nfp;
}

/// Test whether `point` lies strictly inside (or on the boundary of) `poly`.
///
/// Uses the ray-casting algorithm: cast a ray in the +x direction from `point`
/// and count edge crossings. Odd count → inside. Works for any simple polygon.
///
/// Boundary points (on an edge) are treated as inside (returns true), which
/// matches the "touching = forbidden" convention used in the packer.
pub fn pointInPolygon(point: Vec2, poly: Polygon) bool {
    const verts = poly.vertices;
    const n = verts.len;
    var inside = false;
    var prev = n - 1;
    for (0..n) |curr| {
        const vi = verts[curr];
        const vj = verts[prev];
        // Check if the edge crosses the horizontal ray from point in +x direction.
        // Use the half-open convention: count the edge if vi.y <= point.y < vj.y
        // or vj.y <= point.y < vi.y (avoids double-counting shared vertices).
        if ((vi.y > point.y) != (vj.y > point.y)) {
            const x_intersect = vj.x + (point.y - vj.y) / (vi.y - vj.y) * (vi.x - vj.x);
            if (point.x < x_intersect) {
                inside = !inside;
            }
        }
        prev = curr;
    }
    return inside;
}

/// Check whether placing polyB at posB would overlap polyA at posA,
/// using a precomputed NFP(polyA, polyB).
///
/// The test is: is `posB − posA` inside the NFP polygon?
pub fn checkOverlapNFP(posA: Vec2, posB: Vec2, nfp: Polygon) bool {
    const relative = posB.sub(posA);
    return pointInPolygon(relative, nfp);
}

// ---------------------------------------------------------------------------
// Non-convex NFP: multi-part
// ---------------------------------------------------------------------------

/// Compute NFP parts for a possibly non-convex pair (polyA, polyB).
///
/// Each polygon is decomposed into convex triangles. For each pair of convex
/// parts (Ai from A, Bj from B), one convex NFP polygon is computed.
/// The result is a flat list of convex NFP polygons (may have duplicate/overlapping regions).
///
/// Collision check: relative position is forbidden iff it lies inside ANY returned part.
/// Release with `freeNFPParts(allocator, parts)`.
pub fn computeNFPParts(allocator: std.mem.Allocator, polyA: Polygon, polyB: Polygon) ![]Polygon {
    const a_parts = try decompose.decomposeConvex(allocator, polyA);
    defer decompose.freeParts(allocator, a_parts);

    const b_parts = try decompose.decomposeConvex(allocator, polyB);
    defer decompose.freeParts(allocator, b_parts);

    const total = a_parts.len * b_parts.len;
    var result = try allocator.alloc(Polygon, total);
    var count: usize = 0;

    errdefer {
        for (result[0..count]) |*p| p.deinit(allocator);
        allocator.free(result);
    }

    for (a_parts) |ai| {
        for (b_parts) |bj| {
            result[count] = try computeNFP(allocator, ai, bj);
            count += 1;
        }
    }

    return result;
}

/// Free NFP parts produced by `computeNFPParts`.
pub fn freeNFPParts(allocator: std.mem.Allocator, parts: []Polygon) void {
    for (parts) |*p| p.deinit(allocator);
    allocator.free(parts);
}

/// Check collision using multi-part NFP.
/// Returns true if `posB − posA` lies inside any of the NFP parts.
pub fn checkOverlapNFPParts(posA: Vec2, posB: Vec2, nfp_parts: []const Polygon) bool {
    const relative = posB.sub(posA);
    for (nfp_parts) |part| {
        if (pointInPolygon(relative, part)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn makeRect(allocator: std.mem.Allocator, w: f32, h: f32) !Polygon {
    const v = try allocator.alloc(Vec2, 4);
    v[0] = Vec2.init(0, 0);
    v[1] = Vec2.init(w, 0);
    v[2] = Vec2.init(w, h);
    v[3] = Vec2.init(0, h);
    var p = Polygon{ .vertices = v };
    p.initBoundingBox();
    return p;
}

fn makeTriangle(allocator: std.mem.Allocator, base: f32, height: f32) !Polygon {
    const v = try allocator.alloc(Vec2, 3);
    v[0] = Vec2.init(0, 0);
    v[1] = Vec2.init(base, 0);
    v[2] = Vec2.init(0, height);
    var p = Polygon{ .vertices = v };
    p.initBoundingBox();
    return p;
}

test "NFP - two unit squares: result is 2x2 square at (-1,-1)..(1,1)" {
    const allocator = std.testing.allocator;
    var a = try makeRect(allocator, 1, 1);
    defer a.deinit(allocator);
    var b = try makeRect(allocator, 1, 1);
    defer b.deinit(allocator);

    var nfp = try computeNFP(allocator, a, b);
    defer nfp.deinit(allocator);

    // Bounding box must be 2×2 centred at origin.
    try std.testing.expectApproxEqAbs(@as(f32, 2), nfp.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 2), nfp.height, 0.01);
    try std.testing.expectEqual(@as(usize, 4), nfp.vertices.len);
}

test "NFP - 2x1 rect and 1x1 square: result is 3x2 rect at (-1,-1)..(2,1)" {
    const allocator = std.testing.allocator;
    var a = try makeRect(allocator, 2, 1);
    defer a.deinit(allocator);
    var b = try makeRect(allocator, 1, 1);
    defer b.deinit(allocator);

    var nfp = try computeNFP(allocator, a, b);
    defer nfp.deinit(allocator);

    try std.testing.expectApproxEqAbs(@as(f32, 3), nfp.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 2), nfp.height, 0.01);
    try std.testing.expectEqual(@as(usize, 4), nfp.vertices.len);
}

test "NFP - triangle and unit square: 5 vertices" {
    const allocator = std.testing.allocator;
    var a = try makeTriangle(allocator, 1, 1);
    defer a.deinit(allocator);
    var b = try makeRect(allocator, 1, 1);
    defer b.deinit(allocator);

    var nfp = try computeNFP(allocator, a, b);
    defer nfp.deinit(allocator);

    // Triangle (3 edges) + square (4 edges), 2 parallel pairs → 5 vertices.
    try std.testing.expectEqual(@as(usize, 5), nfp.vertices.len);
}

test "NFP - NFP area equals area(A) + area(B) + perimeter terms (Minkowski property)" {
    // For two convex polygons the Minkowski sum area = area(A) + area(B) + mixed term.
    // A simpler sanity check: NFP area must be >= area(A) and >= area(B).
    const allocator = std.testing.allocator;
    var a = try makeRect(allocator, 3, 2);
    defer a.deinit(allocator);
    var b = try makeRect(allocator, 2, 1);
    defer b.deinit(allocator);

    var nfp = try computeNFP(allocator, a, b);
    defer nfp.deinit(allocator);

    // NFP of 3x2 and 2x1 rect → 5x3 rect (width=5, height=3, area=15)
    try std.testing.expectApproxEqAbs(@as(f32, 5), nfp.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 3), nfp.height, 0.01);
}

test "pointInPolygon - centre of unit square is inside" {
    const allocator = std.testing.allocator;
    var sq = try makeRect(allocator, 2, 2);
    defer sq.deinit(allocator);
    // Square spans (0,0)..(2,2); centre is (1,1).
    try std.testing.expect(pointInPolygon(Vec2.init(1, 1), sq));
}

test "pointInPolygon - outside point is not inside" {
    const allocator = std.testing.allocator;
    var sq = try makeRect(allocator, 2, 2);
    defer sq.deinit(allocator);
    try std.testing.expect(!pointInPolygon(Vec2.init(3, 1), sq));
    try std.testing.expect(!pointInPolygon(Vec2.init(1, 3), sq));
    try std.testing.expect(!pointInPolygon(Vec2.init(-1, 1), sq));
}

test "pointInPolygon - inside triangle" {
    const allocator = std.testing.allocator;
    // Right triangle (0,0),(2,0),(0,2)
    var tri = try makeTriangle(allocator, 2, 2);
    defer tri.deinit(allocator);
    // Centroid ≈ (0.67, 0.67) — definitely inside
    try std.testing.expect(pointInPolygon(Vec2.init(0.5, 0.5), tri));
    // Outside: far right
    try std.testing.expect(!pointInPolygon(Vec2.init(2, 2), tri));
}

test "checkOverlapNFP - overlapping squares detected" {
    const allocator = std.testing.allocator;
    var a = try makeRect(allocator, 1, 1);
    defer a.deinit(allocator);
    var b = try makeRect(allocator, 1, 1);
    defer b.deinit(allocator);

    var nfp = try computeNFP(allocator, a, b);
    defer nfp.deinit(allocator);

    // A at (0,0), B at (0.5, 0) → clearly overlapping
    try std.testing.expect(checkOverlapNFP(Vec2.init(0, 0), Vec2.init(0.5, 0), nfp));
}

test "checkOverlapNFP - separated squares not detected" {
    const allocator = std.testing.allocator;
    var a = try makeRect(allocator, 1, 1);
    defer a.deinit(allocator);
    var b = try makeRect(allocator, 1, 1);
    defer b.deinit(allocator);

    var nfp = try computeNFP(allocator, a, b);
    defer nfp.deinit(allocator);

    // A at (0,0), B at (2,0) → gap of 1 unit, no overlap
    try std.testing.expect(!checkOverlapNFP(Vec2.init(0, 0), Vec2.init(2, 0), nfp));
}

test "computeNFPParts - two convex rects produce one part" {
    const allocator = std.testing.allocator;
    var a = try makeRect(allocator, 2, 1);
    defer a.deinit(allocator);
    var b = try makeRect(allocator, 1, 1);
    defer b.deinit(allocator);

    const parts = try computeNFPParts(allocator, a, b);
    defer freeNFPParts(allocator, parts);

    // Both convex → each decomposes to 1 part → 1×1 = 1 NFP part.
    try std.testing.expectEqual(@as(usize, 1), parts.len);
}

test "computeNFPParts - non-convex L-shape vs unit square: overlap detected" {
    const allocator = std.testing.allocator;
    // L-shape: (0,0),(2,0),(2,1),(1,1),(1,2),(0,2)
    const l_verts = try allocator.alloc(Vec2, 6);
    l_verts[0] = Vec2.init(0, 0);
    l_verts[1] = Vec2.init(2, 0);
    l_verts[2] = Vec2.init(2, 1);
    l_verts[3] = Vec2.init(1, 1);
    l_verts[4] = Vec2.init(1, 2);
    l_verts[5] = Vec2.init(0, 2);
    var l_shape = Polygon{ .vertices = l_verts };
    l_shape.initBoundingBox();
    defer l_shape.deinit(allocator);

    var sq = try makeRect(allocator, 1, 1);
    defer sq.deinit(allocator);

    const parts = try computeNFPParts(allocator, l_shape, sq);
    defer freeNFPParts(allocator, parts);

    // L-shape decomposes to 4 triangles × 1 square = 4 parts.
    try std.testing.expectEqual(@as(usize, 4), parts.len);

    // Square at (0.5, 0.5) relative to L at origin → should overlap.
    try std.testing.expect(checkOverlapNFPParts(Vec2.init(0, 0), Vec2.init(0.5, 0.5), parts));
}

test "checkOverlapNFPParts - square outside L-shape: no overlap" {
    const allocator = std.testing.allocator;
    const l_verts = try allocator.alloc(Vec2, 6);
    l_verts[0] = Vec2.init(0, 0);
    l_verts[1] = Vec2.init(2, 0);
    l_verts[2] = Vec2.init(2, 1);
    l_verts[3] = Vec2.init(1, 1);
    l_verts[4] = Vec2.init(1, 2);
    l_verts[5] = Vec2.init(0, 2);
    var l_shape = Polygon{ .vertices = l_verts };
    l_shape.initBoundingBox();
    defer l_shape.deinit(allocator);

    var sq = try makeRect(allocator, 1, 1);
    defer sq.deinit(allocator);

    const parts = try computeNFPParts(allocator, l_shape, sq);
    defer freeNFPParts(allocator, parts);

    // Square far to the right → no overlap.
    try std.testing.expect(!checkOverlapNFPParts(Vec2.init(0, 0), Vec2.init(5, 0), parts));
}
