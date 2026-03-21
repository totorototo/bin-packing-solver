const std = @import("std");
const bps = @import("bin_packing_solver");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    // Generate random convex polygons
    const num_pieces = 100;
    var pieces = std.ArrayList(bps.Polygon){};
    defer {
        for (pieces.items) |*p| p.deinit(allocator);
        pieces.deinit(allocator);
    }

    std.debug.print("🔧 Generating {d} random convex polygons...\n", .{num_pieces});
    for (0..num_pieces) |_| {
        const size = 5.0 + random.float(f32) * 10.0;
        try pieces.append(allocator, try bps.generateRandomConvex(allocator, random, size));
    }

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

    // Export result to SVG
    std.debug.print("\n📁 Exporting result to SVG...\n", .{});
    var filename_buf: [128]u8 = undefined;
    const filename = try std.fmt.bufPrint(&filename_buf, "nesting_{d}.svg", .{std.time.timestamp()});
    try bps.exportToSVG(result.placed_items.items, result.final_length, 50.0, filename, result.efficiency);
    std.debug.print("   Saved to: {s}\n", .{filename});
}
