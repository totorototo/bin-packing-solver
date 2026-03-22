//! Lazy NFP cache: memoises computeNFPParts results keyed by
//! (placed_piece_idx, placed_rot_idx, new_piece_idx, new_rot_idx).
//!
//! Because piece shapes and rotation angles are fixed for the lifetime of a
//! GeneticAlgorithm run, every unique (piece_a × rot_a × piece_b × rot_b)
//! combination always produces the same NFP parts.  Computing them once and
//! reusing them across all fitness evaluations eliminates the dominant cost
//! (decompose + Minkowski sum) from the inner loop.
//!
//! The rotated polygon table is owned by GeneticAlgorithm and passed in at
//! init time; the cache borrows it and never calls rotateByAngle itself.
//!
//! The cache is NOT thread-safe; each worker thread owns its own instance.

const std = @import("std");
const Polygon = @import("polygon.zig").Polygon;
const nfp_mod = @import("nfp.zig");

const CacheKey = struct {
    a_piece: u32,
    a_rot_idx: u8,
    b_piece: u32,
    b_rot_idx: u8,
};

pub const NfpCache = struct {
    map: std.AutoHashMap(CacheKey, []Polygon),
    /// Borrowed from GeneticAlgorithm: rotated[piece_idx][rot_idx].
    /// Not owned by the cache; do not free in deinit.
    rotated: []const []Polygon,
    rotation_angles: []const f32,
    allocator: std.mem.Allocator,

    /// Init is infallible: the rotated table is pre-built by the GA.
    pub fn init(
        allocator: std.mem.Allocator,
        rotated: []const []Polygon,
        rotation_angles: []const f32,
    ) NfpCache {
        return .{
            .map = std.AutoHashMap(CacheKey, []Polygon).init(allocator),
            .rotated = rotated,
            .rotation_angles = rotation_angles,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NfpCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |parts_ptr| {
            nfp_mod.freeNFPParts(self.allocator, parts_ptr.*);
        }
        self.map.deinit();
        // rotated is borrowed — not freed here.
    }

    /// Map a rotation angle (degrees) to its index in rotation_angles.
    /// Returns 0 if not found (should never happen in normal use).
    pub fn rotIdx(self: *const NfpCache, angle: f32) u8 {
        for (self.rotation_angles, 0..) |a, i| {
            if (@abs(a - angle) < 1e-4) return @intCast(i);
        }
        return 0;
    }

    /// Return the NFP parts for (piece_a @ rot_a) vs (piece_b @ rot_b),
    /// computing and caching them on the first call.
    /// Borrows the precomputed rotated polygons — no rotateByAngle call.
    /// The returned slice is owned by the cache; do NOT free it.
    pub fn getOrCompute(
        self: *NfpCache,
        a_piece: usize,
        a_rot_idx: u8,
        b_piece: usize,
        b_rot_idx: u8,
    ) ![]Polygon {
        const key = CacheKey{
            .a_piece = @intCast(a_piece),
            .a_rot_idx = a_rot_idx,
            .b_piece = @intCast(b_piece),
            .b_rot_idx = b_rot_idx,
        };

        if (self.map.get(key)) |parts| return parts;

        // Borrow precomputed rotated polygons from the GA's table.
        const a_rot = self.rotated[a_piece][a_rot_idx];
        const b_rot = self.rotated[b_piece][b_rot_idx];

        const parts = try nfp_mod.computeNFPParts(self.allocator, a_rot, b_rot);
        try self.map.put(key, parts);
        return parts;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn makeRect(allocator: std.mem.Allocator, w: f32, h: f32) !Polygon {
    const Vec2 = @import("vec2.zig").Vec2;
    const v = try allocator.alloc(Vec2, 4);
    v[0] = Vec2.init(0, 0);
    v[1] = Vec2.init(w, 0);
    v[2] = Vec2.init(w, h);
    v[3] = Vec2.init(0, h);
    var p = Polygon{ .vertices = v };
    p.initBoundingBox();
    return p;
}

/// Build a rotated_pieces table for testing: [piece][rot_idx].
/// Caller must free with freeRotatedTable.
fn buildRotatedTable(
    allocator: std.mem.Allocator,
    pieces: []const Polygon,
    angles: []const f32,
) ![][]Polygon {
    const table = try allocator.alloc([]Polygon, pieces.len);
    var n_built: usize = 0;
    errdefer {
        for (table[0..n_built]) |row| {
            for (row) |*p| p.deinit(allocator);
            allocator.free(row);
        }
        allocator.free(table);
    }
    for (pieces, 0..) |piece, pi| {
        const row = try allocator.alloc(Polygon, angles.len);
        errdefer allocator.free(row);
        var n_rots: usize = 0;
        errdefer for (row[0..n_rots]) |*p| p.deinit(allocator);
        for (angles, 0..) |angle, ri| {
            row[ri] = try piece.rotateByAngle(allocator, angle);
            n_rots += 1;
        }
        table[pi] = row;
        n_built += 1;
    }
    return table;
}

fn freeRotatedTable(allocator: std.mem.Allocator, table: [][]Polygon) void {
    for (table) |row| {
        for (row) |*p| p.deinit(allocator);
        allocator.free(row);
    }
    allocator.free(table);
}

test "NfpCache - same key returns same slice pointer (no recompute)" {
    const allocator = std.testing.allocator;
    var a = try makeRect(allocator, 2, 1);
    defer a.deinit(allocator);
    var b = try makeRect(allocator, 1, 1);
    defer b.deinit(allocator);

    const pieces = [_]Polygon{ a, b };
    const angles = [_]f32{ 0, 90 };

    const table = try buildRotatedTable(allocator, &pieces, &angles);
    defer freeRotatedTable(allocator, table);

    var cache = NfpCache.init(allocator, table, &angles);
    defer cache.deinit();

    const parts1 = try cache.getOrCompute(0, 0, 1, 0);
    const parts2 = try cache.getOrCompute(0, 0, 1, 0);
    // Same slice pointer means cache hit.
    try std.testing.expectEqual(parts1.ptr, parts2.ptr);
}

test "NfpCache - different rotation produces different entry" {
    const allocator = std.testing.allocator;
    var a = try makeRect(allocator, 2, 1);
    defer a.deinit(allocator);
    var b = try makeRect(allocator, 1, 1);
    defer b.deinit(allocator);

    const pieces = [_]Polygon{ a, b };
    const angles = [_]f32{ 0, 90 };

    const table = try buildRotatedTable(allocator, &pieces, &angles);
    defer freeRotatedTable(allocator, table);

    var cache = NfpCache.init(allocator, table, &angles);
    defer cache.deinit();

    const parts_r0 = try cache.getOrCompute(0, 0, 1, 0);
    const parts_r1 = try cache.getOrCompute(0, 1, 1, 0);
    try std.testing.expect(parts_r0.ptr != parts_r1.ptr);
}

test "NfpCache - rotIdx maps angle correctly" {
    const allocator = std.testing.allocator;
    var sq = try makeRect(allocator, 1, 1);
    defer sq.deinit(allocator);
    const pieces = [_]Polygon{sq};
    const angles = [_]f32{ 0, 45, 90, 135, 180, 225, 270, 315 };

    const table = try buildRotatedTable(allocator, &pieces, &angles);
    defer freeRotatedTable(allocator, table);

    var cache = NfpCache.init(allocator, table, &angles);
    defer cache.deinit();

    try std.testing.expectEqual(@as(u8, 0), cache.rotIdx(0));
    try std.testing.expectEqual(@as(u8, 2), cache.rotIdx(90));
    try std.testing.expectEqual(@as(u8, 7), cache.rotIdx(315));
    // Unknown angle falls back to 0.
    try std.testing.expectEqual(@as(u8, 0), cache.rotIdx(999));
}
