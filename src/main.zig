const std = @import("std");
const bps = @import("bin_packing_solver");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    // Generate random convex polygons
    const num_pieces = 20;
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

    // Perform nesting using the exported function from root.zig
    const strip_height: f32 = 50.0;
    const num_cores: usize = 4;
    const population_per_core: usize = 20;
    const generations: usize = 100;
    const migration_interval: usize = 10;

    var result = try bps.performNesting(
        allocator,
        pieces.items,
        strip_height,
        num_cores,
        population_per_core,
        generations,
        migration_interval,
    );
    defer result.deinit();

    // Export result to SVG
    std.debug.print("\n📁 Exporting result to SVG...\n", .{});
    var filename_buf: [128]u8 = undefined;
    const filename = try std.fmt.bufPrint(&filename_buf, "nesting_{d}.svg", .{std.time.timestamp()});
    try bps.exportToSVG(result.placed_items.items, result.final_width, strip_height, filename, result.efficiency);
    std.debug.print("   Saved to: {s}\n", .{filename});
}
