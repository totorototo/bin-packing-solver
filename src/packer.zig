const std = @import("std");
const Vec2 = @import("vec2.zig").Vec2;
const Polygon = @import("polygon.zig").Polygon;
const PlacedItem = @import("placed_item.zig").PlacedItem;
const isOverlappingSAT = @import("sat.zig").isOverlappingSAT;

pub const Packer = struct {
    strip_height: f32,
    placed_items: std.ArrayList(PlacedItem),
    grid_resolution: f32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, height: f32, grid_resolution: f32) Packer {
        return .{
            .allocator = allocator,
            .strip_height = height,
            .grid_resolution = grid_resolution,
            .placed_items = .{},
        };
    }

    pub fn deinit(self: *Packer) void {
        for (self.placed_items.items) |*item| {
            item.poly.deinit(self.allocator);
        }
        self.placed_items.deinit(self.allocator);
    }

    fn aabbOverlap(aPos: Vec2, aW: f32, aH: f32, bPos: Vec2, bW: f32, bH: f32) bool {
        if (aPos.x + aW <= bPos.x or bPos.x + bW <= aPos.x) return false;
        if (aPos.y + aH <= bPos.y or bPos.y + bH <= aPos.y) return false;
        return true;
    }

    fn checkOverlap(self: *Packer, poly: Polygon, test_pos: Vec2) bool {
        if (test_pos.x < 0 or test_pos.y < 0) return true;
        if (test_pos.y + poly.height > self.strip_height) return true;

        for (self.placed_items.items) |item| {
            if (!aabbOverlap(test_pos, poly.width, poly.height, item.pos, item.poly.width, item.poly.height)) continue;
            if (isOverlappingSAT(poly, test_pos, item.poly, item.pos)) {
                return true;
            }
        }
        return false;
    }

    pub fn placePolygon(self: *Packer, poly: Polygon, piece_id: usize, rotation: f32) !?PlacedItem {
        const max_search_width = self.getMaxWidth() + poly.width + 50.0;
        var best_pos: ?Vec2 = null;
        var best_x: f32 = std.math.floatMax(f32);

        var x: f32 = 0;
        while (x <= max_search_width) : (x += self.grid_resolution) {
            var y: f32 = 0;
            while (y <= self.strip_height - poly.height) : (y += self.grid_resolution) {
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

    pub fn getMaxWidth(self: *Packer) f32 {
        var max_x: f32 = 0;
        for (self.placed_items.items) |item| {
            max_x = @max(max_x, item.pos.x + item.poly.width);
        }
        return max_x;
    }

    pub fn calculateEfficiency(self: *Packer) f32 {
        var total_area: f32 = 0;
        const max_x = self.getMaxWidth();
        for (self.placed_items.items) |item| {
            total_area += item.poly.area;
        }
        const used_area = self.strip_height * max_x;
        if (used_area < 0.0001) return 0;
        return (total_area / used_area) * 100.0;
    }
};

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
