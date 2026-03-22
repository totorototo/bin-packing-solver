//! Mutex-guarded fitness cache shared across all worker threads.
//!
//! Each GA instance has its own NFP cache and rotated-polygon table, but the
//! chromosome-fingerprint → fitness mapping is pure (same input always yields
//! the same fitness) so it is safe to share across threads.  Sharing lets
//! every core benefit from evaluations already done by other cores, e.g.
//! when migration imports a chromosome that a sibling core already scored.
//!
//! The cache is accessed only through `get` / `put`; the mutex is held for
//! the minimum time needed (hash-map lookup / insert only — never during the
//! full fitness evaluation).

const std = @import("std");

pub const SharedFitnessCache = struct {
    map: std.AutoHashMap(u64, f32),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SharedFitnessCache {
        return .{
            .map = std.AutoHashMap(u64, f32).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SharedFitnessCache) void {
        self.map.deinit();
    }

    pub fn get(self: *SharedFitnessCache, key: u64) ?f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(key);
    }

    pub fn put(self: *SharedFitnessCache, key: u64, value: f32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.map.put(key, value);
    }
};
