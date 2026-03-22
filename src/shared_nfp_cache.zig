//! Thread-safe NFP cache shared across all worker threads.
//!
//! Each GA core independently re-computes the same Minkowski sums for identical
//! piece-pair × rotation combinations.  This cache eliminates that redundancy:
//! the first core to need a given (a_piece, a_rot, b_piece, b_rot) computes it
//! once; every subsequent request from any core gets the cached result.
//!
//! Ownership: the cache owns all allocated []Polygon values and frees them in
//! deinit.  Callers receive a borrowed slice — they must NOT free it.
//!
//! Thread-safety: uses a single Mutex.  To avoid holding the lock during the
//! expensive computeNFPParts call, getOrCompute uses a double-checked pattern:
//!   1. Lock → check → unlock            (fast path, most calls after warm-up)
//!   2. Compute without holding the lock  (slow path, one-time per unique key)
//!   3. Lock → check again → insert or discard → unlock

const std = @import("std");
const Polygon = @import("polygon.zig").Polygon;
const nfp_mod = @import("nfp.zig");

const CacheKey = struct {
    a_piece: u32,
    a_rot_idx: u8,
    b_piece: u32,
    b_rot_idx: u8,
};

pub const SharedNfpCache = struct {
    map: std.AutoHashMap(CacheKey, []Polygon),
    mutex: std.Thread.Mutex,
    rotation_angles: []const f32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, rotation_angles: []const f32) SharedNfpCache {
        return .{
            .map = std.AutoHashMap(CacheKey, []Polygon).init(allocator),
            .mutex = .{},
            .rotation_angles = rotation_angles,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SharedNfpCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |parts_ptr| {
            nfp_mod.freeNFPParts(self.allocator, parts_ptr.*);
        }
        self.map.deinit();
    }

    /// Map a rotation angle to its index. Returns 0 if not found.
    pub fn rotIdx(self: *const SharedNfpCache, angle: f32) u8 {
        for (self.rotation_angles, 0..) |a, i| {
            if (@abs(a - angle) < 1e-4) return @intCast(i);
        }
        return 0;
    }

    /// Return NFP parts for (piece_a @ rot_a) vs (piece_b @ rot_b).
    /// On the first call for a given key the parts are computed and stored;
    /// all subsequent calls (from any thread) return the cached slice.
    /// The returned slice is owned by the cache — do NOT free it.
    pub fn getOrCompute(
        self: *SharedNfpCache,
        a_piece: usize,
        a_rot_idx: u8,
        b_piece: usize,
        b_rot_idx: u8,
        a_rot: Polygon,
        b_rot: Polygon,
    ) ![]Polygon {
        const key = CacheKey{
            .a_piece = @intCast(a_piece),
            .a_rot_idx = a_rot_idx,
            .b_piece = @intCast(b_piece),
            .b_rot_idx = b_rot_idx,
        };

        // Phase 1: fast check under lock.
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.map.get(key)) |parts| return parts;
        }

        // Phase 2: compute without holding the lock.
        const new_parts = try nfp_mod.computeNFPParts(self.allocator, a_rot, b_rot);

        // Phase 3: insert under lock; discard if another thread beat us.
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.map.get(key)) |existing| {
                nfp_mod.freeNFPParts(self.allocator, new_parts);
                return existing;
            }
            self.map.put(key, new_parts) catch |err| {
                nfp_mod.freeNFPParts(self.allocator, new_parts);
                return err;
            };
            return new_parts;
        }
    }
};
