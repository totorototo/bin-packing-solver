const std = @import("std");

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn dot(self: Vec2, other: Vec2) f32 {
        return self.x * other.x + self.y * other.y;
    }

    pub fn perp(self: Vec2) Vec2 {
        return .{ .x = -self.y, .y = self.x };
    }

    pub fn length(self: Vec2) f32 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn normalize(self: Vec2) Vec2 {
        const len = self.length();
        if (len < 0.0001) return .{ .x = 0, .y = 0 };
        return .{ .x = self.x / len, .y = self.y / len };
    }
};

test "Vec2 add" {
    const a = Vec2.init(1, 2);
    const b = Vec2.init(3, 4);
    const c = a.add(b);
    try std.testing.expectApproxEqAbs(@as(f32, 4), c.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 6), c.y, 0.001);
}

test "Vec2 sub" {
    const a = Vec2.init(5, 3);
    const b = Vec2.init(2, 1);
    const c = a.sub(b);
    try std.testing.expectApproxEqAbs(@as(f32, 3), c.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), c.y, 0.001);
}

test "Vec2 dot" {
    const a = Vec2.init(1, 2);
    const b = Vec2.init(3, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 11), a.dot(b), 0.001);
}

test "Vec2 dot - perpendicular vectors are zero" {
    const a = Vec2.init(1, 0);
    const b = Vec2.init(0, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0), a.dot(b), 0.001);
}

test "Vec2 perp" {
    const v = Vec2.init(3, 4);
    const p = v.perp();
    // perp rotates 90°: (-y, x)
    try std.testing.expectApproxEqAbs(@as(f32, -4), p.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), p.y, 0.001);
    // perp should be perpendicular to original
    try std.testing.expectApproxEqAbs(@as(f32, 0), v.dot(p), 0.001);
}

test "Vec2 length" {
    const v = Vec2.init(3, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 5), v.length(), 0.001);
}

test "Vec2 normalize - unit vector" {
    const v = Vec2.init(3, 4);
    const n = v.normalize();
    try std.testing.expectApproxEqAbs(@as(f32, 1), n.length(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), n.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), n.y, 0.001);
}

test "Vec2 normalize - near-zero vector returns zero" {
    const v = Vec2.init(0.00001, 0);
    const n = v.normalize();
    try std.testing.expectApproxEqAbs(@as(f32, 0), n.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), n.y, 0.001);
}
