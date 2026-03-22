# Bin Packing Solver

[![CI](https://github.com/totorototo/bin-packing-solver/actions/workflows/ci.yml/badge.svg)](https://github.com/totorototo/bin-packing-solver/actions/workflows/ci.yml)

A high-performance 2D bin packing / nesting library written in Zig, using a multi-core genetic algorithm for optimal polygon placement.

## Features

- 🧬 **Multi-core Genetic Algorithm** - Parallel optimization across CPU cores with migration between populations
- 🔄 **Rotation Support** - 8 rotation angles (0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°)
- 📐 **Non-Convex Polygon Support** - Works with arbitrary simple polygons (convex and non-convex)
- 🎯 **Adaptive Collision Detection** - SAT (Separating Axis Theorem) for convex pieces; NFP (No-Fit Polygon / Minkowski sum) for non-convex pieces — selected automatically
- 📊 **SVG Export** - Visualize results with automatic SVG generation
- ⚡ **Zero Dependencies** - Pure Zig implementation

## Installation

Add to your `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/totorototo/bin-packing-solver
```

Then in your `build.zig`:

```zig
const bin_packing_solver = b.dependency("bin_packing_solver", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("bin_packing_solver", bin_packing_solver.module("bin_packing_solver"));
```

## Usage

```zig
const std = @import("std");
const bps = @import("bin_packing_solver");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    var pieces = std.ArrayList(bps.Polygon).init(allocator);
    defer {
        for (pieces.items) |*p| p.deinit(allocator);
        pieces.deinit();
    }

    // Generate random convex and concave pieces
    for (0..20) |_| {
        const size = 5.0 + random.float(f32) * 10.0;
        try pieces.append(try bps.generateRandomConvex(allocator, random, size));
    }
    for (0..10) |_| {
        const size = 5.0 + random.float(f32) * 10.0;
        try pieces.append(try bps.generateRandomConcave(allocator, random, size));
    }

    // Or construct a polygon directly from vertices using Polygon.init
    const verts = [_]bps.Vec2{
        .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 },
        .{ .x = 4, .y = 3 }, .{ .x = 0, .y = 3 },
    };
    try pieces.append(try bps.Polygon.init(allocator, &verts));

    // Perform nesting
    var result = try bps.performNesting(allocator, pieces.items, .{
        .strip_width = 50.0,      // fixed dimension (e.g. fabric roll width)
        .num_cores = 4,
        .population_per_core = 20,
        .generations = 100,
        .migration_interval = 10,
        .stagnation_limit = 20,   // stop early if no improvement (0 = disabled)
        .grid_resolution = 5.0,   // placement grid step size (convex mode only)
        .verbose = false,
    });
    defer result.deinit();

    std.debug.print("Length: {d:.2}, Efficiency: {d:.2}%\n", .{
        result.final_length,
        result.efficiency,
    });

    // Export to SVG
    try bps.exportToSVG(result.placed_items.items, result.final_length, 50.0, "output.svg", result.efficiency);
}
```

## API

### `performNesting`

```zig
pub fn performNesting(
    allocator: std.mem.Allocator,
    pieces: []Polygon,
    config: NestingConfig,
) !NestingResult
```

Runs the genetic algorithm to find an optimal placement. Returns a `NestingResult` that must be freed with `result.deinit()`.

### `NestingConfig`

| Field | Type | Default | Description |
|---|---|---|---|
| `strip_width` | `f32` | *(required)* | Fixed dimension of the strip (e.g. fabric roll width) |
| `num_cores` | `usize` | `4` | Number of parallel GA populations |
| `population_per_core` | `usize` | `20` | Chromosomes per population |
| `generations` | `usize` | `100` | Maximum number of generations |
| `migration_interval` | `usize` | `10` | Generations between cross-population migrations |
| `stagnation_limit` | `usize` | `20` | Early stop after N generations without improvement (`0` = disabled) |
| `grid_resolution` | `f32` | `5.0` | Placement grid step size for convex mode (smaller = more precise, slower). Unused in non-convex NFP mode. |
| `verbose` | `bool` | `false` | Print progress to stderr |
| `piece_constraints` | `?[]const PieceConstraints` | `null` | Per-piece rotation constraints |

### `NestingError`

| Error | Description |
|---|---|
| `NoPieces` | Empty pieces slice |
| `InvalidStripWidth` | `strip_width` ≤ 0 |
| `InvalidNumCores` | `num_cores` = 0 |
| `InvalidGridResolution` | `grid_resolution` ≤ 0 |
| `PieceTooWideForStrip` | A piece's height exceeds `strip_width` |

### `NestingResult`

| Field | Type | Description |
|---|---|---|
| `placed_items` | `ArrayList(PlacedItem)` | All placed polygons with position and rotation |
| `final_length` | `f32` | Total strip length used (the minimized dimension) |
| `efficiency` | `f32` | Area utilization percentage |
| `best_fitness` | `f32` | Raw fitness value from the GA |

### Types

- `Polygon` - Simple polygon (convex or non-convex) with vertices, bounding box, and area. Use `Polygon.init(allocator, verts)` to construct from a vertex slice.
- `Vec2` - 2D vector (`x`, `y`)
- `PlacedItem` - A placed polygon with `pos`, `rotation`, and `piece_id`
- `PieceConstraints` - Per-piece allowed rotation angles
- `RotationConstraints` - Rotation constraint definitions

### Helpers

- `generateRandomConvex(allocator, random, size)` - Generate a random convex polygon
- `generateRandomConcave(allocator, random, size)` - Generate a random concave (non-convex) polygon
- `exportToSVG(items, length, width, filename, efficiency)` - Export placement to SVG

## Building

```bash
# Build the library
zig build

# Run tests
zig build test

# Run the example
zig build run

# Run benchmark suite
zig build bench
zig build bench -Doptimize=ReleaseFast  # for representative timing
```

## Benchmarks

`src/bench.zig` defines seven deterministic cases with known theoretical lower bounds:

| Case | Pieces | Strip width | Shape type |
|------|--------|-------------|------------|
| 01 identical squares | 20 | 5.0 | 1×1 squares (convex) |
| 02 mixed rectangles | 12 | 10.0 | 1×2, 2×3, 3×4 rects (convex) |
| 03 right triangles 4×3 | 16 | 8.0 | right triangles (convex) |
| 04 hexagons r=2 | 12 | 14.0 | regular hexagons (convex) |
| 05 stress mixed | 40 | 15.0 | squares + rects + triangles + hexagons (convex) |
| 06 L-shapes | 12 | 5.0 | L-shaped pieces (non-convex) |
| 07 mixed non-convex | 20 | 8.0 | L + T + Z shapes (non-convex) |

Cases 01–05 use SAT-based collision detection (convex pieces). Cases 06–07 automatically switch to NFP-based exact placement (non-convex pieces, no grid quantization).

Each run reports `lower_bound` (total area / strip width), achieved `length`, `efficiency` %, and a `ratio` (1.000 = optimal). See [benchmarks/README.md](benchmarks/README.md) for reference results and interpretation.

## Algorithm

The solver uses a Biased Random-Key Genetic Algorithm (BRKGA) with:

1. **Encoding** - Each chromosome contains a permutation (placement order) and rotation angles per piece
2. **Decoding** - Bottom-left-fill heuristic with AABB broad-phase + SAT (convex) or NFP-vertex exact placement (non-convex)
3. **Selection** - Elitist selection with biased crossover (30% elite, 20% mutants)
4. **Migration** - Best solutions migrate between parallel populations every N generations
5. **Early stop** - Stagnation detection halts cores that stop improving

## License

MIT License - see [LICENSE](LICENSE) for details.
