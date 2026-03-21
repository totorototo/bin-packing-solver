const std = @import("std");
const Vec2 = @import("vec2.zig").Vec2;
const Polygon = @import("polygon.zig").Polygon;
const PlacedItem = @import("placed_item.zig").PlacedItem;

/// Jarvis march convex hull. Returns a newly allocated slice of hull vertices.
fn convexHull(allocator: std.mem.Allocator, points: []const Vec2) ![]Vec2 {
    if (points.len < 3) return allocator.dupe(Vec2, points);

    // Find leftmost point as start
    var start: usize = 0;
    for (points, 0..) |p, i| {
        if (p.x < points[start].x or (p.x == points[start].x and p.y < points[start].y)) {
            start = i;
        }
    }

    const buf = try allocator.alloc(Vec2, points.len);
    var hull_len: usize = 0;

    var current = start;
    while (true) {
        buf[hull_len] = points[current];
        hull_len += 1;
        var next: usize = if (current == 0) 1 else 0;
        for (points, 0..) |_, i| {
            if (i == current) continue;
            const a = points[current];
            const b = points[next];
            const c = points[i];
            const cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
            if (cross < 0) next = i;
        }
        current = next;
        if (current == start or hull_len >= points.len) break;
    }

    const result = try allocator.alloc(Vec2, hull_len);
    @memcpy(result, buf[0..hull_len]);
    allocator.free(buf);
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

pub fn exportToSVG(items: []const PlacedItem, width: f32, height: f32, filename: []const u8, efficiency: f32) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    var buffer: [65536]u8 = undefined;
    var w = file.writer(&buffer);
    const writer = &w.interface;

    try writer.print(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<svg viewBox="0 0 {d} {d}" xmlns="http://www.w3.org/2000/svg" style="background:#1a1a1a">
        \\  <text x="5" y="15" fill="#00ff00" font-size="12">Efficiency: {d:.2}% (Multi-core)</text>
        \\
    , .{ width, height, efficiency });

    for (items) |item| {
        const hue = (@as(u32, @intFromFloat(@as(f32, @floatFromInt(item.piece_id)) * 137.508)) % 360);
        const r = @as(u8, @intFromFloat(127 + 127 * @cos(@as(f32, @floatFromInt(hue)) * 0.017453)));
        const g = @as(u8, @intFromFloat(127 + 127 * @cos((@as(f32, @floatFromInt(hue)) + 120) * 0.017453)));
        const b = @as(u8, @intFromFloat(127 + 127 * @cos((@as(f32, @floatFromInt(hue)) + 240) * 0.017453)));

        try writer.print("  <polygon points=\"", .{});
        for (item.poly.vertices) |v| {
            try writer.print("{d:.2},{d:.2} ", .{ v.x + item.pos.x, v.y + item.pos.y });
        }
        try writer.print("\" fill=\"rgb({d},{d},{d})\" stroke=\"#fff\" stroke-width=\"0.1\" fill-opacity=\"0.6\"/>\n", .{ r, g, b });
    }

    try writer.writeAll("</svg>");
    try writer.flush();
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

test "exportToSVG - produces file with SVG header" {
    const allocator = std.testing.allocator;
    const verts = try allocator.alloc(Vec2, 4);
    verts[0] = Vec2.init(0, 0);
    verts[1] = Vec2.init(3, 0);
    verts[2] = Vec2.init(3, 3);
    verts[3] = Vec2.init(0, 3);
    var poly = Polygon{ .vertices = verts };
    poly.initBoundingBox();
    defer poly.deinit(allocator);

    const item = PlacedItem{ .poly = poly, .pos = Vec2.init(0, 0), .rotation = 0, .piece_id = 0 };
    const items = [_]PlacedItem{item};

    const tmp_path = "test_svg_export_tmp.svg";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    try exportToSVG(&items, 10, 10, tmp_path, 90.0);

    const file = try std.fs.cwd().openFile(tmp_path, .{});
    defer file.close();
    var buf: [64]u8 = undefined;
    const n = try file.read(&buf);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "<?xml"));
}
