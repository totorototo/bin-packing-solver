# Bin Packing Solver

A high-performance 2D bin packing / nesting library written in Zig, using a multi-core genetic algorithm for optimal polygon placement.

## Features

- 🧬 **Multi-core Genetic Algorithm** - Parallel optimization across CPU cores with migration between populations
- 🔄 **Rotation Support** - 8 rotation angles (0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°)
- 📐 **Convex Polygon Support** - Works with arbitrary convex polygons
- 🎯 **SAT Collision Detection** - Precise overlap detection using Separating Axis Theorem
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

    // Create polygons
    var pieces = std.ArrayList(bps.Polygon){};
    defer {
        for (pieces.items) |*p| p.deinit(allocator);
        pieces.deinit(allocator);
    }

    // Add your polygons here...
    // try pieces.append(allocator, your_polygon);

    // Perform nesting
    var result = try bps.performNesting(
        allocator,
        pieces.items,
        50.0,  // strip_height
        4,     // num_cores
        20,    // population_per_core
        100,   // generations
        10,    // migration_interval
    );
    defer result.deinit();

    // Export to SVG
    try bps.exportToSVG(result.placed_items.items, result.final_width, 50.0, "output.svg", result.efficiency);
}
```

## API

### Main Functions

- `performNesting` - Run the genetic algorithm to find optimal placement
- `performNestingWithConstraints` - Same as above but with rotation constraints per piece

### Types

- `Polygon` - Convex polygon representation
- `Vec2` - 2D vector
- `PlacedItem` - A placed polygon with position and rotation
- `NestingResult` - Result containing placed items and statistics
- `PieceConstraints` - Per-piece constraints (allowed rotations, etc.)

### Helpers

- `generateRandomConvex` - Generate random convex polygons for testing
- `exportToSVG` - Export placement results to SVG

## Building

```bash
# Build the library
zig build

# Run tests
zig build test

# Run the example
zig build run
```

## Algorithm

The solver uses a Biased Random-Key Genetic Algorithm (BRKGA) with:

1. **Encoding**: Each chromosome contains a permutation (placement order) and rotation angles
2. **Decoding**: Bottom-left-fill heuristic with collision detection
3. **Selection**: Elitist selection with biased crossover
4. **Migration**: Best solutions migrate between parallel populations

## License

MIT License - see [LICENSE](LICENSE) for details.
