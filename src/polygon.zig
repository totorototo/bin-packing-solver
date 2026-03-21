const std = @import("std");
const Vec2 = @import("vec2.zig").Vec2;

pub const Polygon = struct {
    vertices: []Vec2,
    width: f32 = 0,
    height: f32 = 0,
    area: f32 = 0,
    centroid: Vec2 = Vec2.init(0, 0),

    pub fn initBoundingBox(self: *Polygon) void {
        if (self.vertices.len == 0) return;
        var max_x: f32 = self.vertices[0].x;
        var max_y: f32 = self.vertices[0].y;
        var min_x: f32 = self.vertices[0].x;
        var min_y: f32 = self.vertices[0].y;

        for (self.vertices) |v| {
            max_x = @max(max_x, v.x);
            max_y = @max(max_y, v.y);
            min_x = @min(min_x, v.x);
            min_y = @min(min_y, v.y);
        }

        self.width = max_x - min_x;
        self.height = max_y - min_y;
        self.area = self.calculateArea();
        self.centroid = self.calculateCentroid();
    }

    pub fn calculateArea(self: Polygon) f32 {
        if (self.vertices.len < 3) return 0;
        var area: f32 = 0;
        for (0..self.vertices.len) |i| {
            const j = (i + 1) % self.vertices.len;
            area += self.vertices[i].x * self.vertices[j].y;
            area -= self.vertices[j].x * self.vertices[i].y;
        }
        return @abs(area / 2.0);
    }

    pub fn calculateCentroid(self: Polygon) Vec2 {
        if (self.vertices.len == 0) return Vec2.init(0, 0);
        const area = self.calculateArea();
        if (area < 0.0001) {
            // Degenerate polygon: fall back to vertex average
            var cx: f32 = 0;
            var cy: f32 = 0;
            for (self.vertices) |v| {
                cx += v.x;
                cy += v.y;
            }
            const n = @as(f32, @floatFromInt(self.vertices.len));
            return Vec2.init(cx / n, cy / n);
        }
        var cx: f32 = 0;
        var cy: f32 = 0;
        for (0..self.vertices.len) |i| {
            const j = (i + 1) % self.vertices.len;
            const cross = self.vertices[i].x * self.vertices[j].y - self.vertices[j].x * self.vertices[i].y;
            cx += (self.vertices[i].x + self.vertices[j].x) * cross;
            cy += (self.vertices[i].y + self.vertices[j].y) * cross;
        }
        const factor = 1.0 / (6.0 * area);
        return Vec2.init(@abs(cx * factor), @abs(cy * factor));
    }

    /// Translate polygon so all coordinates start exactly at (0, 0)
    pub fn normalizeToPositive(self: *Polygon) void {
        if (self.vertices.len == 0) return;

        var min_x: f32 = self.vertices[0].x;
        var min_y: f32 = self.vertices[0].y;

        for (self.vertices) |v| {
            min_x = @min(min_x, v.x);
            min_y = @min(min_y, v.y);
        }

        // Translate all vertices so min is exactly at (0, 0)
        for (self.vertices) |*v| {
            v.x -= min_x;
            v.y -= min_y;
        }
    }

    pub fn rotateByAngle(self: Polygon, allocator: std.mem.Allocator, angle_degrees: f32) !Polygon {
        const angle_rad = angle_degrees * std.math.pi / 180.0;
        const cos_a = @cos(angle_rad);
        const sin_a = @sin(angle_rad);

        const new_verts = try allocator.alloc(Vec2, self.vertices.len);
        for (self.vertices, 0..) |v, i| {
            new_verts[i] = Vec2.init(
                v.x * cos_a - v.y * sin_a,
                v.x * sin_a + v.y * cos_a,
            );
        }

        var rotated = Polygon{ .vertices = new_verts };
        rotated.normalizeToPositive();
        rotated.initBoundingBox();
        return rotated;
    }

    pub fn clone(self: Polygon, allocator: std.mem.Allocator) !Polygon {
        const new_verts = try allocator.alloc(Vec2, self.vertices.len);
        @memcpy(new_verts, self.vertices);
        return Polygon{
            .vertices = new_verts,
            .width = self.width,
            .height = self.height,
            .area = self.area,
            .centroid = self.centroid,
        };
    }

    /// Returns true if the polygon is convex (all cross products have the same sign).
    pub fn isConvex(self: Polygon) bool {
        if (self.vertices.len < 3) return false;
        var sign: i32 = 0;
        for (0..self.vertices.len) |i| {
            const a = self.vertices[i];
            const b = self.vertices[(i + 1) % self.vertices.len];
            const c = self.vertices[(i + 2) % self.vertices.len];
            const cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
            if (cross > 0.0001) {
                if (sign == -1) return false;
                sign = 1;
            } else if (cross < -0.0001) {
                if (sign == 1) return false;
                sign = -1;
            }
        }
        return true;
    }

    pub fn deinit(self: *Polygon, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
    }
};

test "Polygon area - unit square" {
    const allocator = std.testing.allocator;
    const verts = try allocator.alloc(Vec2, 4);
    verts[0] = Vec2.init(0, 0);
    verts[1] = Vec2.init(1, 0);
    verts[2] = Vec2.init(1, 1);
    verts[3] = Vec2.init(0, 1);
    var p = Polygon{ .vertices = verts };
    defer p.deinit(allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), p.calculateArea(), 0.001);
}

test "Polygon centroid - unit square" {
    const allocator = std.testing.allocator;
    const verts = try allocator.alloc(Vec2, 4);
    verts[0] = Vec2.init(0, 0);
    verts[1] = Vec2.init(2, 0);
    verts[2] = Vec2.init(2, 2);
    verts[3] = Vec2.init(0, 2);
    var p = Polygon{ .vertices = verts };
    defer p.deinit(allocator);
    const c = p.calculateCentroid();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c.y, 0.001);
}

test "Polygon isConvex - square is convex" {
    const allocator = std.testing.allocator;
    const verts = try allocator.alloc(Vec2, 4);
    verts[0] = Vec2.init(0, 0);
    verts[1] = Vec2.init(1, 0);
    verts[2] = Vec2.init(1, 1);
    verts[3] = Vec2.init(0, 1);
    var p = Polygon{ .vertices = verts };
    defer p.deinit(allocator);
    try std.testing.expect(p.isConvex());
}

test "Polygon isConvex - L-shape is not convex" {
    const allocator = std.testing.allocator;
    const verts = try allocator.alloc(Vec2, 6);
    verts[0] = Vec2.init(0, 0);
    verts[1] = Vec2.init(2, 0);
    verts[2] = Vec2.init(2, 1);
    verts[3] = Vec2.init(1, 1);
    verts[4] = Vec2.init(1, 2);
    verts[5] = Vec2.init(0, 2);
    var p = Polygon{ .vertices = verts };
    defer p.deinit(allocator);
    try std.testing.expect(!p.isConvex());
}

test "Polygon rotation preserves area" {
    const allocator = std.testing.allocator;
    const verts = try allocator.alloc(Vec2, 4);
    verts[0] = Vec2.init(0, 0);
    verts[1] = Vec2.init(3, 0);
    verts[2] = Vec2.init(3, 2);
    verts[3] = Vec2.init(0, 2);
    var p = Polygon{ .vertices = verts };
    p.initBoundingBox();
    defer p.deinit(allocator);
    const original_area = p.calculateArea();
    var rotated = try p.rotateByAngle(allocator, 90);
    defer rotated.deinit(allocator);
    try std.testing.expectApproxEqAbs(original_area, rotated.calculateArea(), 0.01);
}
