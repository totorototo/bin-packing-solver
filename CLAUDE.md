# CLAUDE.md

See parent `../CLAUDE.md` for full ecosystem context (astm-parser, bin-packing-solver, nesting-pipeline).

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
zig build          # build the library + executable
zig build run      # build and run src/main.zig
zig build test     # run all tests across all modules
```

To run a single test by name:
```bash
zig build test 2>&1 | grep -A3 "test name"
# Zig does not support running a single test file directly when modules are involved;
# use `zig test src/polygon.zig` for files with no cross-module imports.
```

## Architecture

This is a library crate (`src/root.zig` is the public API) plus a demo executable (`src/main.zig`). The build wires them as separate modules in `build.zig`.

### Data flow

```
performNesting (nesting.zig)
  └─ auto-detects non-convex pieces → sets use_nfp=true if any piece is non-convex
  └─ spawns N threads → workerThread (worker_thread.zig)
       └─ GeneticAlgorithm (genetic_algorithm.zig)
            └─ evaluateFitness → Packer (packer.zig)
                 ├─ [convex]     AABB broad-phase → isOverlappingSAT (sat.zig)
                 └─ [non-convex] AABB broad-phase → computeNFPParts → checkOverlapNFPParts (nfp.zig)
                      └─ computeNFPParts: decomposeConvex (decompose.zig) → pairwise computeNFP
  └─ MigrationPool (migration_pool.zig)   ← shared between threads, mutex-guarded
  └─ best Chromosome → final Packer run → NestingResult
```

### Key types and their responsibilities

| Type | File | Role |
|---|---|---|
| `Polygon` | `polygon.zig` | Simple polygon (convex or non-convex): vertices, AABB (`width`/`height`), `area`, `centroid`. Must call `initBoundingBox()` after construction. |
| `Chromosome` | `chromosome.zig` | GA individual: `sequence[]usize` (piece order) + `rotations[]f32` (one angle per piece). `piece_constraints` is a shared (non-owned) reference. |
| `GeneticAlgorithm` | `genetic_algorithm.zig` | BRKGA: elitism (30%), mutants (20%), crossover (OX1 with rotation inheritance), mutation rate 0.05. |
| `Packer` | `packer.zig` | Bottom-left-fill placement. Grid-scan over X then Y; breaks on first valid Y per X column. Fitness = `getLength()` (X extent). |
| `MigrationPool` | `migration_pool.zig` | One slot per core; each core submits its best and imports the best from another core. Mutex-protected. |
| `WorkerContext` | `worker_context.zig` | Input/output struct passed to each thread. After join, read `best_result` and `best_fitness`. |
| `PieceConstraints` | `piece_constraints.zig` | Per-piece allowed rotation angles. Supports `free`, `fixed`, `flip_only`, `quarter_only` via `RotationConstraint` enum. |

### Terminology (domain: fabric nesting)

- **strip_width** — the fixed dimension (fabric roll width, Y axis). Constrained.
- **length** / `final_length` — the minimized dimension (X axis, fabric consumed). This is the fitness value.
- Fitness = strip length used. Lower is better. `floatMax(f32)` signals a failed placement.

### Memory ownership rules

- `Polygon.vertices` is always heap-allocated and owned by the polygon; free with `poly.deinit(allocator)`.
- `PlacedItem` returned by `Packer.placePolygon` contains a **cloned** polygon — caller must free it.
- `Chromosome.piece_constraints` is a **shared reference**, never freed by the chromosome.
- `NestingResult` owns all its `PlacedItem` polygons; free with `result.deinit()`.

### Adding a new module

1. Create `src/your_module.zig`.
2. Import it in the files that need it (`@import("your_module.zig")`).
3. If it should be public API, re-export from `src/root.zig`.

### SAT touching-edges behaviour

`isOverlappingSAT` uses strict `<` comparison on interval overlap. Two polygons that share exactly one edge are considered **overlapping** by the implementation. Tests reflect this intentional behaviour.

### Non-convex polygon support

`performNesting` accepts any simple polygon (CCW winding, no self-intersections). If any piece is non-convex, it automatically switches to NFP-based collision detection (`use_nfp=true`) for all pieces.

The NFP pipeline:
- `decompose.zig` — ear-clipping triangulation: decomposes a simple polygon into triangles (all convex)
- `nfp.zig` — Minkowski sum for convex pairs (O(n+m)); `computeNFPParts` calls decompose on both polygons and returns all pairwise convex NFPs as a flat `[]Polygon`
- Collision test: relative position inside ANY NFP part → forbidden

`generateRandomConvex` in `helpers.zig` uses Jarvis march (gift wrapping) to guarantee convex output.
