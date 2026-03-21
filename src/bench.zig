//! Benchmark suite for the bin-packing-solver.
//!
//! Run with:
//!   zig build bench                          # debug build
//!   zig build bench -Doptimize=ReleaseFast   # for realistic timing
//!
//! Each case uses fixed, deterministic polygon sets so results are
//! reproducible across implementations. Because the GA is stochastic,
//! quality (ratio/efficiency) will vary slightly between runs; timing
//! will vary with hardware and optimization level.
//!
//! Metrics
//! -------
//!   lower_bound  = total_piece_area / strip_width  (theoretical minimum length)
//!   ratio        = final_length / lower_bound       (1.0 = optimal, lower is better)
//!   efficiency   = total_piece_area / (strip_width * final_length)  × 100 %

const std = @import("std");
const bps = @import("bin_packing_solver");

// ---------------------------------------------------------------------------
// Polygon construction helpers
// ---------------------------------------------------------------------------

/// Axis-aligned rectangle, CCW winding, width × height.
fn makeRect(allocator: std.mem.Allocator, w: f32, h: f32) !bps.Polygon {
    const verts = try allocator.alloc(bps.Vec2, 4);
    verts[0] = bps.Vec2.init(0, 0);
    verts[1] = bps.Vec2.init(w, 0);
    verts[2] = bps.Vec2.init(w, h);
    verts[3] = bps.Vec2.init(0, h);
    var poly = bps.Polygon{ .vertices = verts };
    poly.initBoundingBox();
    return poly;
}

/// Right triangle, legs `base` × `height`, CCW winding.
fn makeRightTriangle(allocator: std.mem.Allocator, base: f32, height: f32) !bps.Polygon {
    const verts = try allocator.alloc(bps.Vec2, 3);
    verts[0] = bps.Vec2.init(0, 0);
    verts[1] = bps.Vec2.init(base, 0);
    verts[2] = bps.Vec2.init(0, height);
    var poly = bps.Polygon{ .vertices = verts };
    poly.initBoundingBox();
    return poly;
}

/// Regular hexagon with the given circumradius. Vertices at angles 0°, 60°, …, 300°
/// shifted so the bounding box starts at (0, 0).
fn makeRegularHexagon(allocator: std.mem.Allocator, radius: f32) !bps.Polygon {
    const verts = try allocator.alloc(bps.Vec2, 6);
    for (0..6) |i| {
        const angle = @as(f32, @floatFromInt(i)) * std.math.pi / 3.0;
        verts[i] = bps.Vec2.init(
            radius * @cos(angle),
            radius * @sin(angle),
        );
    }
    var poly = bps.Polygon{ .vertices = verts };
    poly.normalizeToPositive();
    poly.initBoundingBox();
    return poly;
}

// ---------------------------------------------------------------------------
// Benchmark result
// ---------------------------------------------------------------------------

const BenchResult = struct {
    name: []const u8,
    num_pieces: usize,
    strip_width: f32,
    lower_bound: f32,
    final_length: f32,
    efficiency: f32,
    ratio: f32,
    time_ms: i64,
};

fn runCase(
    allocator: std.mem.Allocator,
    name: []const u8,
    pieces: []bps.Polygon,
    lower_bound: f32,
    config: bps.NestingConfig,
) !BenchResult {
    const t0 = std.time.milliTimestamp();
    var result = try bps.performNesting(allocator, pieces, config);
    defer result.deinit();
    const elapsed = std.time.milliTimestamp() - t0;
    return BenchResult{
        .name = name,
        .num_pieces = pieces.len,
        .strip_width = config.strip_width,
        .lower_bound = lower_bound,
        .final_length = result.final_length,
        .efficiency = result.efficiency,
        .ratio = result.final_length / lower_bound,
        .time_ms = elapsed,
    };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Bin Packing Solver Benchmark ===\n\n", .{});
    std.debug.print(
        "{s:<32} {s:>6} {s:>8} {s:>10} {s:>10} {s:>9} {s:>7} {s:>9}\n",
        .{ "Case", "Pieces", "Width", "LowerBnd", "Length", "Effic%", "Ratio", "Time(ms)" },
    );
    std.debug.print("{s}\n", .{"-" ** 95});

    var results = std.ArrayList(BenchResult){};
    defer results.deinit(allocator);

    // -----------------------------------------------------------------------
    // Case 1 — 20 identical unit squares, strip_width = 5
    //   Pieces tile perfectly into a 5 × 4 rectangle ⇒ lower_bound = 4.0
    // -----------------------------------------------------------------------
    {
        const n = 20;
        const strip_width: f32 = 5.0;
        const piece_area: f32 = 1.0 * 1.0;
        const lower_bound = @as(f32, @floatFromInt(n)) * piece_area / strip_width;

        const pieces = try allocator.alloc(bps.Polygon, n);
        defer {
            for (pieces) |*p| p.deinit(allocator);
            allocator.free(pieces);
        }
        for (pieces) |*p| p.* = try makeRect(allocator, 1.0, 1.0);

        const r = try runCase(allocator, "01_identical_squares", pieces, lower_bound, .{
            .strip_width = strip_width,
            .num_cores = 4,
            .population_per_core = 30,
            .generations = 200,
            .grid_resolution = 0.5,
        });
        try results.append(allocator, r);
    }

    // -----------------------------------------------------------------------
    // Case 2 — 12 mixed rectangles (4 × 1×2, 4 × 2×3, 4 × 3×4), strip_width = 10
    //   total_area = 4*(2 + 6 + 12) = 80  →  lower_bound = 8.0
    // -----------------------------------------------------------------------
    {
        const repeat = 4;
        const sizes = [_][2]f32{ .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 } };
        const n = sizes.len * repeat;
        const strip_width: f32 = 10.0;
        const total_area: f32 = @as(f32, @floatFromInt(repeat)) * (1 * 2 + 2 * 3 + 3 * 4);
        const lower_bound = total_area / strip_width;

        var pieces = try allocator.alloc(bps.Polygon, n);
        defer {
            for (pieces) |*p| p.deinit(allocator);
            allocator.free(pieces);
        }
        var idx: usize = 0;
        for (sizes) |sz| {
            for (0..repeat) |_| {
                pieces[idx] = try makeRect(allocator, sz[0], sz[1]);
                idx += 1;
            }
        }

        const r = try runCase(allocator, "02_mixed_rectangles", pieces, lower_bound, .{
            .strip_width = strip_width,
            .num_cores = 4,
            .population_per_core = 30,
            .generations = 200,
            .grid_resolution = 0.5,
        });
        try results.append(allocator, r);
    }

    // -----------------------------------------------------------------------
    // Case 3 — 16 right triangles (legs 4 × 3), strip_width = 8
    //   two mirrored triangles tile into a 4 × 3 rectangle, so pairs pack
    //   at 100 % density ⇒ lower_bound = 12.0
    // -----------------------------------------------------------------------
    {
        const n = 16;
        const strip_width: f32 = 8.0;
        const piece_area: f32 = 0.5 * 4.0 * 3.0;
        const lower_bound = @as(f32, @floatFromInt(n)) * piece_area / strip_width;

        const pieces = try allocator.alloc(bps.Polygon, n);
        defer {
            for (pieces) |*p| p.deinit(allocator);
            allocator.free(pieces);
        }
        for (pieces) |*p| p.* = try makeRightTriangle(allocator, 4.0, 3.0);

        const r = try runCase(allocator, "03_right_triangles_4x3", pieces, lower_bound, .{
            .strip_width = strip_width,
            .num_cores = 4,
            .population_per_core = 30,
            .generations = 200,
            .grid_resolution = 0.5,
        });
        try results.append(allocator, r);
    }

    // -----------------------------------------------------------------------
    // Case 4 — 12 regular hexagons (circumradius = 2), strip_width = 14
    //   hex_area = (3√3/2) × r²  ≈ 10.39 each → total ≈ 124.7
    //   lower_bound ≈ 8.91
    // -----------------------------------------------------------------------
    {
        const n = 12;
        const strip_width: f32 = 14.0;
        const r_hex: f32 = 2.0;
        const hex_area = 3.0 * @sqrt(@as(f32, 3.0)) / 2.0 * r_hex * r_hex;
        const total_area = @as(f32, @floatFromInt(n)) * hex_area;
        const lower_bound = total_area / strip_width;

        const pieces = try allocator.alloc(bps.Polygon, n);
        defer {
            for (pieces) |*p| p.deinit(allocator);
            allocator.free(pieces);
        }
        for (pieces) |*p| p.* = try makeRegularHexagon(allocator, r_hex);

        const r = try runCase(allocator, "04_hexagons_r2", pieces, lower_bound, .{
            .strip_width = strip_width,
            .num_cores = 4,
            .population_per_core = 30,
            .generations = 200,
            .grid_resolution = 0.5,
        });
        try results.append(allocator, r);
    }

    // -----------------------------------------------------------------------
    // Case 5 — stress: 40 mixed pieces (rectangles + triangles + hexagons)
    //   strip_width = 15
    // -----------------------------------------------------------------------
    {
        // 5 × (1×1) + 5 × (2×1) + 5 × (3×2) + 15 right-triangles(2×3) + 10 hexagons(r=1)
        const n_sq = 5;
        const n_r21 = 5;
        const n_r32 = 5;
        const n_tri = 15;
        const n_hex = 10;
        const n = n_sq + n_r21 + n_r32 + n_tri + n_hex;
        const strip_width: f32 = 15.0;

        const r_hex: f32 = 1.0;
        const hex_area = 3.0 * @sqrt(@as(f32, 3.0)) / 2.0 * r_hex * r_hex;
        const total_area: f32 =
            @as(f32, @floatFromInt(n_sq)) * 1.0 * 1.0 +
            @as(f32, @floatFromInt(n_r21)) * 2.0 * 1.0 +
            @as(f32, @floatFromInt(n_r32)) * 3.0 * 2.0 +
            @as(f32, @floatFromInt(n_tri)) * 0.5 * 2.0 * 3.0 +
            @as(f32, @floatFromInt(n_hex)) * hex_area;
        const lower_bound = total_area / strip_width;

        var pieces = try allocator.alloc(bps.Polygon, n);
        defer {
            for (pieces) |*p| p.deinit(allocator);
            allocator.free(pieces);
        }
        var idx: usize = 0;
        for (0..n_sq) |_| {
            pieces[idx] = try makeRect(allocator, 1.0, 1.0);
            idx += 1;
        }
        for (0..n_r21) |_| {
            pieces[idx] = try makeRect(allocator, 2.0, 1.0);
            idx += 1;
        }
        for (0..n_r32) |_| {
            pieces[idx] = try makeRect(allocator, 3.0, 2.0);
            idx += 1;
        }
        for (0..n_tri) |_| {
            pieces[idx] = try makeRightTriangle(allocator, 2.0, 3.0);
            idx += 1;
        }
        for (0..n_hex) |_| {
            pieces[idx] = try makeRegularHexagon(allocator, r_hex);
            idx += 1;
        }

        const res = try runCase(allocator, "05_stress_mixed_40pcs", pieces, lower_bound, .{
            .strip_width = strip_width,
            .num_cores = 4,
            .population_per_core = 20,
            .generations = 150,
            .grid_resolution = 0.5,
        });
        try results.append(allocator, res);
    }

    // -----------------------------------------------------------------------
    // Print results table
    // -----------------------------------------------------------------------
    for (results.items) |r| {
        std.debug.print(
            "{s:<32} {d:>6} {d:>8.1} {d:>10.3} {d:>10.3} {d:>8.1}% {d:>7.3} {d:>9}\n",
            .{ r.name, r.num_pieces, r.strip_width, r.lower_bound,
               r.final_length, r.efficiency, r.ratio, r.time_ms },
        );
    }
    std.debug.print("{s}\n", .{"-" ** 95});
    std.debug.print(
        \\
        \\  ratio = final_length / lower_bound  (1.000 = optimal; lower is better)
        \\  lower_bound = total_piece_area / strip_width  (area-based theoretical floor)
        \\
        \\  Note: results are stochastic — rerun to gauge variance.
        \\  For fair timing, use: zig build bench -Doptimize=ReleaseFast
        \\
    , .{});
}
