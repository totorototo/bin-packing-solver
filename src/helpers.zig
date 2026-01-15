const std = @import("std");
const Vec2 = @import("vec2.zig").Vec2;
const Polygon = @import("polygon.zig").Polygon;
const PlacedItem = @import("placed_item.zig").PlacedItem;

pub fn generateRandomConvex(allocator: std.mem.Allocator, rand: std.Random, size: f32) !Polygon {
    const num_points = rand.intRangeAtMost(usize, 4, 18);
    var angles = try allocator.alloc(f32, num_points);
    defer allocator.free(angles);

    for (0..num_points) |i| {
        angles[i] = rand.float(f32) * std.math.pi * 2.0;
    }
    std.mem.sort(f32, angles, {}, std.sort.asc(f32));

    var verts = try allocator.alloc(Vec2, num_points);
    for (0..num_points) |i| {
        const r = size * (0.5 + rand.float(f32) * 0.5);
        verts[i] = Vec2.init(@cos(angles[i]) * r, @sin(angles[i]) * r);
    }

    var p = Polygon{ .vertices = verts };
    p.normalizeToPositive(); // Normalize coordinates to be positive
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
