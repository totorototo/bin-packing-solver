const std = @import("std");
const Vec2 = @import("vec2.zig").Vec2;
const Polygon = @import("polygon.zig").Polygon;
const PlacedItem = @import("placed_item.zig").PlacedItem;
const isOverlappingSAT = @import("sat.zig").isOverlappingSAT;
const nfp_mod = @import("nfp.zig");
const NfpCache = @import("nfp_cache.zig").NfpCache;

pub const Packer = struct {
    strip_width: f32,
    placed_items: std.ArrayList(PlacedItem),
    grid_resolution: f32,
    allocator: std.mem.Allocator,
    /// When true, use NFP-based collision detection instead of SAT.
    /// NFP handles any convex polygon pair and is the foundation for
    /// eventually supporting non-convex pieces.
    use_nfp: bool = false,
    /// Optional precomputed NFP cache.  When non-null, placePolygonWithNFP
    /// borrows NFP parts from it instead of recomputing them each call.
    /// The cache is owned by the caller (GeneticAlgorithm); the Packer
    /// only holds a borrowed pointer.
    nfp_cache: ?*NfpCache = null,
    /// Reusable buffer for NFP-vertex candidate positions.
    /// Allocated once per Packer lifetime; cleared (without freeing) between
    /// placements so the underlying memory is reused across all pieces in an
    /// evaluation instead of being reallocated from scratch each time.
    candidates_buf: std.ArrayList(Vec2),

    pub fn init(allocator: std.mem.Allocator, strip_width: f32, grid_resolution: f32) Packer {
        return .{
            .allocator = allocator,
            .strip_width = strip_width,
            .grid_resolution = grid_resolution,
            .placed_items = .{},
            .candidates_buf = .{},
        };
    }

    pub fn deinit(self: *Packer) void {
        for (self.placed_items.items) |*item| {
            item.poly.deinit(self.allocator);
        }
        self.placed_items.deinit(self.allocator);
        self.candidates_buf.deinit(self.allocator);
    }

    fn aabbOverlap(aPos: Vec2, aW: f32, aH: f32, bPos: Vec2, bW: f32, bH: f32) bool {
        if (aPos.x + aW <= bPos.x or bPos.x + bW <= aPos.x) return false;
        if (aPos.y + aH <= bPos.y or bPos.y + bH <= aPos.y) return false;
        return true;
    }

    fn checkOverlap(self: *Packer, poly: Polygon, test_pos: Vec2) bool {
        if (test_pos.x < 0 or test_pos.y < 0) return true;
        if (test_pos.y + poly.height > self.strip_width) return true;

        for (self.placed_items.items) |item| {
            if (!aabbOverlap(test_pos, poly.width, poly.height, item.pos, item.poly.width, item.poly.height)) continue;
            if (isOverlappingSAT(poly, test_pos, item.poly, item.pos)) {
                return true;
            }
        }
        return false;
    }

    /// NFP-aware overlap check using precomputed multi-part NFPs.
    fn checkOverlapNFP(self: *Packer, poly: Polygon, test_pos: Vec2, nfp_parts_list: []const []Polygon) bool {
        if (test_pos.x < 0 or test_pos.y < 0) return true;
        if (test_pos.y + poly.height > self.strip_width) return true;
        for (self.placed_items.items, 0..) |item, idx| {
            if (!aabbOverlap(test_pos, poly.width, poly.height, item.pos, item.poly.width, item.poly.height)) continue;
            if (nfp_mod.checkOverlapNFPParts(item.pos, test_pos, nfp_parts_list[idx])) return true;
        }
        return false;
    }

    /// Place `poly` using NFP-based collision detection (supports non-convex polygons).
    /// Finds the leftmost-bottommost valid position from the finite set of NFP-vertex
    /// candidates.  This is exact (no grid quantization) and O(n²·m) per evaluation.
    ///
    /// When `self.nfp_cache` is set, NFP parts are looked up (or lazily computed once)
    /// from the cache — eliminating redundant decomposition + Minkowski sums across the
    /// thousands of fitness evaluations in a GA run.  Without a cache the parts are
    /// computed and freed on every call (original behaviour, used for the final pack).
    fn placePolygonWithNFP(self: *Packer, poly: Polygon, piece_id: usize, rotation: f32) !?PlacedItem {
        const n_placed = self.placed_items.items.len;

        // nfp_parts_list[i] — slice of NFP polygons for placed_items[i] vs poly.
        // Ownership depends on whether we have a cache:
        //   cache path   → borrowed from cache, must NOT free elements
        //   no-cache path → owned here,          MUST free elements
        const nfp_parts_list = try self.allocator.alloc([]Polygon, n_placed);

        if (self.nfp_cache) |cache| {
            // --- Cache path: borrow, no element ownership ---
            defer self.allocator.free(nfp_parts_list);

            const b_rot_idx = cache.rotIdx(rotation);
            for (self.placed_items.items, 0..) |item, i| {
                const a_rot_idx = cache.rotIdx(item.rotation);
                nfp_parts_list[i] = try cache.getOrCompute(
                    item.piece_id, a_rot_idx,
                    piece_id, b_rot_idx,
                );
            }

            return self.selectBestPosition(poly, piece_id, rotation, nfp_parts_list);
        } else {
            // --- No-cache path: own and free elements (original behaviour) ---
            var computed: usize = 0;
            errdefer {
                for (nfp_parts_list[0..computed]) |parts| nfp_mod.freeNFPParts(self.allocator, parts);
                self.allocator.free(nfp_parts_list);
            }
            for (self.placed_items.items) |item| {
                nfp_parts_list[computed] = try nfp_mod.computeNFPParts(self.allocator, item.poly, poly);
                computed += 1;
            }
            defer {
                for (nfp_parts_list) |parts| nfp_mod.freeNFPParts(self.allocator, parts);
                self.allocator.free(nfp_parts_list);
            }

            return self.selectBestPosition(poly, piece_id, rotation, nfp_parts_list);
        }
    }

    /// Common placement logic shared by both cache and no-cache paths.
    /// Builds NFP-vertex candidate positions, sorts them by x then y, and
    /// returns the leftmost-bottommost valid placement.
    fn selectBestPosition(
        self: *Packer,
        poly: Polygon,
        piece_id: usize,
        rotation: f32,
        nfp_parts_list: []const []Polygon,
    ) !?PlacedItem {
        // Build candidate positions. The optimal BLF placement always lies either
        // at (0,0), on the strip boundary, or touching another piece — i.e. at a
        // translated NFP vertex. For each NFP vertex we also try sliding to y=0
        // (bottom of strip) and y=strip_width-poly.height (top of strip) at that x.
        //
        // Reuse self.candidates_buf across calls: clearRetainingCapacity keeps
        // the heap allocation alive so later (larger) placements in the same
        // evaluation avoid repeated growing reallocations.
        self.candidates_buf.clearRetainingCapacity();
        const candidates = &self.candidates_buf;

        try candidates.append(self.allocator, Vec2.init(0, 0));
        if (self.strip_width > poly.height) {
            try candidates.append(self.allocator, Vec2.init(0, self.strip_width - poly.height));
        }

        for (self.placed_items.items, 0..) |item, idx| {
            for (nfp_parts_list[idx]) |part| {
                for (part.vertices) |v| {
                    const abs = item.pos.add(v);
                    // Pre-filter: skip candidates that are trivially outside valid bounds.
                    // checkOverlapNFP would reject these anyway, but skipping early avoids
                    // the full NFP collision test for out-of-bounds positions.
                    if (abs.x >= 0) {
                        try candidates.append(self.allocator, abs);
                        try candidates.append(self.allocator, Vec2.init(abs.x, 0));
                        if (self.strip_width > poly.height)
                            try candidates.append(self.allocator, Vec2.init(abs.x, self.strip_width - poly.height));
                    }
                    if (abs.y >= 0 and abs.y + poly.height <= self.strip_width)
                        try candidates.append(self.allocator, Vec2.init(0, abs.y));
                }
            }
        }

        // Sort by x (then y) so we can break as soon as x exceeds the best found so far.
        // Uses exact float comparison (not epsilon) to satisfy strict weak ordering —
        // an epsilon-based comparator can violate transitivity of the equivalence
        // relation and trigger usize underflow inside the block sort algorithm.
        // The epsilon early-exit below is independent and unaffected by this choice.
        std.mem.sort(Vec2, candidates.items, {}, struct {
            fn lessThan(_: void, a: Vec2, b: Vec2) bool {
                if (a.x != b.x) return a.x < b.x;
                return a.y < b.y;
            }
        }.lessThan);

        // Select the leftmost (then bottommost) valid candidate.
        var best_pos: ?Vec2 = null;
        var best_x: f32 = std.math.floatMax(f32);
        var best_y: f32 = std.math.floatMax(f32);

        for (candidates.items) |candidate| {
            // Since candidates are sorted by x, once we're past best_x we can stop.
            if (best_pos != null and candidate.x > best_x + 1e-6) break;
            if (self.checkOverlapNFP(poly, candidate, nfp_parts_list)) continue;
            if (candidate.x < best_x - 1e-6 or
                (candidate.x < best_x + 1e-6 and candidate.y < best_y - 1e-6))
            {
                best_x = candidate.x;
                best_y = candidate.y;
                best_pos = candidate;
            }
        }

        if (best_pos) |pos| {
            const placed_poly = try poly.clone(self.allocator);
            return PlacedItem{
                .poly = placed_poly,
                .pos = pos,
                .rotation = rotation,
                .piece_id = piece_id,
            };
        }
        return null;
    }

    pub fn placePolygon(self: *Packer, poly: Polygon, piece_id: usize, rotation: f32) !?PlacedItem {
        if (self.use_nfp) return self.placePolygonWithNFP(poly, piece_id, rotation);

        const max_search_length = self.getLength() + poly.width + 50.0;
        var best_pos: ?Vec2 = null;
        var best_x: f32 = std.math.floatMax(f32);

        var x: f32 = 0;
        while (x <= max_search_length) : (x += self.grid_resolution) {
            var y: f32 = 0;
            while (y <= self.strip_width - poly.height) : (y += self.grid_resolution) {
                const test_pos = Vec2.init(x, y);
                if (!self.checkOverlap(poly, test_pos)) {
                    if (x < best_x) {
                        best_x = x;
                        best_pos = test_pos;
                        break;
                    }
                }
            }
            if (best_pos != null and x > best_x + self.grid_resolution) {
                break;
            }
        }

        if (best_pos) |pos| {
            const placed_poly = try poly.clone(self.allocator);
            return PlacedItem{
                .poly = placed_poly,
                .pos = pos,
                .rotation = rotation,
                .piece_id = piece_id,
            };
        }
        return null;
    }

    pub fn getLength(self: *Packer) f32 {
        var max_x: f32 = 0;
        for (self.placed_items.items) |item| {
            max_x = @max(max_x, item.pos.x + item.poly.width);
        }
        return max_x;
    }

    pub fn calculateEfficiency(self: *Packer) f32 {
        var total_area: f32 = 0;
        const max_x = self.getLength();
        for (self.placed_items.items) |item| {
            total_area += item.poly.area;
        }
        const used_area = self.strip_width * max_x;
        if (used_area < 0.0001) return 0;
        return (total_area / used_area) * 100.0;
    }
};

test "Packer getLength - empty packer returns zero" {
    const allocator = std.testing.allocator;
    var packer = Packer.init(allocator, 10.0, 1.0);
    defer packer.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 0), packer.getLength(), 0.001);
}

test "Packer calculateEfficiency - empty packer returns zero" {
    const allocator = std.testing.allocator;
    var packer = Packer.init(allocator, 10.0, 1.0);
    defer packer.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 0), packer.calculateEfficiency(), 0.001);
}

test "Packer calculateEfficiency - square filling strip exactly is 100%" {
    const allocator = std.testing.allocator;
    // strip_width = 4, place a 4x4 square → area = 16, used_area = 4*4 = 16
    var packer = Packer.init(allocator, 4.0, 1.0);
    defer packer.deinit();

    const verts = try allocator.alloc(Vec2, 4);
    verts[0] = Vec2.init(0, 0);
    verts[1] = Vec2.init(4, 0);
    verts[2] = Vec2.init(4, 4);
    verts[3] = Vec2.init(0, 4);
    var poly = Polygon{ .vertices = verts };
    poly.initBoundingBox();
    defer poly.deinit(allocator);

    const placement = try packer.placePolygon(poly, 0, 0);
    try std.testing.expect(placement != null);
    try packer.placed_items.append(allocator, placement.?);

    try std.testing.expectApproxEqAbs(@as(f32, 100.0), packer.calculateEfficiency(), 0.1);
}

test "Packer calculateEfficiency - partial fill is less than 100%" {
    const allocator = std.testing.allocator;
    // strip_width = 10, place a 2x2 square → area = 4, used_area = 10*2 = 20 → 20%
    var packer = Packer.init(allocator, 10.0, 1.0);
    defer packer.deinit();

    const verts = try allocator.alloc(Vec2, 4);
    verts[0] = Vec2.init(0, 0);
    verts[1] = Vec2.init(2, 0);
    verts[2] = Vec2.init(2, 2);
    verts[3] = Vec2.init(0, 2);
    var poly = Polygon{ .vertices = verts };
    poly.initBoundingBox();
    defer poly.deinit(allocator);

    const placement = try packer.placePolygon(poly, 0, 0);
    try std.testing.expect(placement != null);
    try packer.placed_items.append(allocator, placement.?);

    try std.testing.expectApproxEqAbs(@as(f32, 20.0), packer.calculateEfficiency(), 0.1);
}

test "Packer places a single square" {
    const allocator = std.testing.allocator;
    var packer = Packer.init(allocator, 10.0, 1.0);
    defer packer.deinit();

    const verts = try allocator.alloc(Vec2, 4);
    verts[0] = Vec2.init(0, 0);
    verts[1] = Vec2.init(3, 0);
    verts[2] = Vec2.init(3, 3);
    verts[3] = Vec2.init(0, 3);
    var poly = Polygon{ .vertices = verts };
    poly.initBoundingBox();
    defer poly.deinit(allocator);

    var result = try packer.placePolygon(poly, 0, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(f32, 0), result.?.rotation);
    result.?.poly.deinit(allocator);
}

test "Packer rejects piece taller than strip" {
    const allocator = std.testing.allocator;
    var packer = Packer.init(allocator, 5.0, 1.0);
    defer packer.deinit();

    const verts = try allocator.alloc(Vec2, 4);
    verts[0] = Vec2.init(0, 0);
    verts[1] = Vec2.init(2, 0);
    verts[2] = Vec2.init(2, 6);
    verts[3] = Vec2.init(0, 6);
    var poly = Polygon{ .vertices = verts };
    poly.initBoundingBox();

    const result = try packer.placePolygon(poly, 0, 0);
    try std.testing.expect(result == null);
    poly.deinit(allocator);
}

test "Packer places two squares side by side" {
    const allocator = std.testing.allocator;
    // Strip height exactly equals piece height, forcing horizontal placement
    var packer = Packer.init(allocator, 4.0, 1.0);
    defer packer.deinit();

    const makeSquare = struct {
        fn f(alloc: std.mem.Allocator, size: f32) !Polygon {
            const v = try alloc.alloc(Vec2, 4);
            v[0] = Vec2.init(0, 0);
            v[1] = Vec2.init(size, 0);
            v[2] = Vec2.init(size, size);
            v[3] = Vec2.init(0, size);
            var p = Polygon{ .vertices = v };
            p.initBoundingBox();
            return p;
        }
    }.f;

    var a = try makeSquare(allocator, 4.0);
    var b = try makeSquare(allocator, 4.0);
    defer a.deinit(allocator);
    defer b.deinit(allocator);

    const r1 = try packer.placePolygon(a, 0, 0);
    try std.testing.expect(r1 != null);
    try packer.placed_items.append(allocator, r1.?);

    var r2 = try packer.placePolygon(b, 1, 0);
    try std.testing.expect(r2 != null);
    // Second square must be placed to the right of the first
    try std.testing.expect(r2.?.pos.x >= 4.0);
    r2.?.poly.deinit(allocator);
}

test "NFP packer places two squares side by side (same as SAT)" {
    const allocator = std.testing.allocator;
    const makeSquare = struct {
        fn f(alloc: std.mem.Allocator, size: f32) !Polygon {
            const v = try alloc.alloc(Vec2, 4);
            v[0] = Vec2.init(0, 0);
            v[1] = Vec2.init(size, 0);
            v[2] = Vec2.init(size, size);
            v[3] = Vec2.init(0, size);
            var p = Polygon{ .vertices = v };
            p.initBoundingBox();
            return p;
        }
    }.f;

    // SAT packer
    var sat_packer = Packer.init(allocator, 4.0, 1.0);
    defer sat_packer.deinit();
    var a1 = try makeSquare(allocator, 4.0);
    var b1 = try makeSquare(allocator, 4.0);
    defer a1.deinit(allocator);
    defer b1.deinit(allocator);
    const sat_r1 = try sat_packer.placePolygon(a1, 0, 0);
    try std.testing.expect(sat_r1 != null);
    try sat_packer.placed_items.append(allocator, sat_r1.?);
    var sat_r2 = try sat_packer.placePolygon(b1, 1, 0);
    try std.testing.expect(sat_r2 != null);
    const sat_x = sat_r2.?.pos.x;
    sat_r2.?.poly.deinit(allocator);

    // NFP packer
    var nfp_packer = blk: {
        var p = Packer.init(allocator, 4.0, 1.0);
        p.use_nfp = true;
        break :blk p;
    };
    defer nfp_packer.deinit();
    var a2 = try makeSquare(allocator, 4.0);
    var b2 = try makeSquare(allocator, 4.0);
    defer a2.deinit(allocator);
    defer b2.deinit(allocator);
    const nfp_r1 = try nfp_packer.placePolygon(a2, 0, 0);
    try std.testing.expect(nfp_r1 != null);
    try nfp_packer.placed_items.append(allocator, nfp_r1.?);
    var nfp_r2 = try nfp_packer.placePolygon(b2, 1, 0);
    try std.testing.expect(nfp_r2 != null);
    const nfp_x = nfp_r2.?.pos.x;
    nfp_r2.?.poly.deinit(allocator);

    // Both should place the second square at the same x position
    try std.testing.expectApproxEqAbs(sat_x, nfp_x, 0.01);
}

test "NFP packer - single square placed at origin" {
    const allocator = std.testing.allocator;
    var packer = blk: {
        var p = Packer.init(allocator, 10.0, 1.0);
        p.use_nfp = true;
        break :blk p;
    };
    defer packer.deinit();

    const v = try allocator.alloc(Vec2, 4);
    v[0] = Vec2.init(0, 0);
    v[1] = Vec2.init(3, 0);
    v[2] = Vec2.init(3, 3);
    v[3] = Vec2.init(0, 3);
    var poly = Polygon{ .vertices = v };
    poly.initBoundingBox();
    defer poly.deinit(allocator);

    var result = try packer.placePolygon(poly, 0, 0);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0), result.?.pos.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), result.?.pos.y, 0.01);
    result.?.poly.deinit(allocator);
}
