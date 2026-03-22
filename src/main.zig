const std = @import("std");
const bps = @import("bin_packing_solver");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    var pieces = std.ArrayList(bps.Polygon){};
    defer {
        for (pieces.items) |*p| p.deinit(allocator);
        pieces.deinit(allocator);
    }

    const num_convex = 30;
    const num_concave = 15;

    std.debug.print("Generating {d} random convex polygons...\n", .{num_convex});
    for (0..num_convex) |_| {
        const size = 5.0 + random.float(f32) * 10.0;
        try pieces.append(allocator, try bps.generateRandomConvex(allocator, random, size));
    }

    std.debug.print("Generating {d} random concave polygons...\n", .{num_concave});
    for (0..num_concave) |_| {
        const size = 5.0 + random.float(f32) * 10.0;
        try pieces.append(allocator, try bps.generateRandomConcave(allocator, random, size));
    }

    std.debug.print("\nTotal: {d} pieces ({d} convex + {d} concave)\n", .{
        pieces.items.len, num_convex, num_concave,
    });
    std.debug.print("Concave pieces trigger automatic NFP-based placement.\n\n", .{});

    const nesting_start = std.time.milliTimestamp();
    var result = try bps.performNesting(allocator, pieces.items, .{
        .strip_width = 50.0,
        .num_cores = 4,
        .population_per_core = 20,
        .generations = 100,
        .migration_interval = 10,
        .verbose = true,
    });
    defer result.deinit();
    const nesting_ms = std.time.milliTimestamp() - nesting_start;
    std.debug.print("\nNesting time: {d}ms ({d:.1}s)\n", .{ nesting_ms, @as(f32, @floatFromInt(nesting_ms)) / 1000.0 });

    const strip_width: f32 = 50.0;
    var total_area: f32 = 0;
    for (result.placed_items.items) |item| total_area += item.poly.area;
    const efficiency = total_area / (strip_width * result.final_length) * 100.0;

    try exportToSVG(result.placed_items.items, result.final_length, strip_width, "output.svg", efficiency);
    std.debug.print("Pieces placed: {d}\nEfficiency: {d:.1}%\nStrip length: {d:.1}\nSaved to: output.svg\n", .{
        result.placed_items.items.len,
        efficiency,
        result.final_length,
    });
}

fn exportToSVG(items: []const bps.PlacedItem, width: f32, height: f32, filename: []const u8, efficiency: f32) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    var buffer: [65536]u8 = undefined;
    var bw = file.writer(&buffer);
    const writer = &bw.interface;

    try writer.print(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<svg viewBox="0 0 {d} {d}" xmlns="http://www.w3.org/2000/svg" style="background:#1a1a1a">
        \\  <text x="5" y="15" fill="#00ff00" font-size="12">Efficiency: {d:.2}%</text>
        \\
    , .{ width, height, efficiency });

    for (items) |item| {
        const hue = (@as(u32, @truncate(item.piece_id)) *% 137) % 360;
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
