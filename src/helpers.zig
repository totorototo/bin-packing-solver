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
