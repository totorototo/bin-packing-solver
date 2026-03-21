# Benchmark Suite

Run the benchmark with:

```bash
zig build bench                         # debug build (slow, easier to iterate)
zig build bench -Doptimize=ReleaseFast  # for representative timing
```

Output goes to stderr. Redirect if you want to save it:

```bash
zig build bench -Doptimize=ReleaseFast 2>results.txt
```

---

## Cases

All polygon sets are **deterministic** (fixed vertex coordinates, no randomness). The GA is stochastic, so quality metrics vary slightly between runs; timing varies with hardware and optimization level.

| # | Name | Pieces | Strip width | Shape type | Notes |
|---|------|--------|-------------|------------|-------|
| 01 | `01_identical_squares` | 20 | 5.0 | 1×1 squares | Fits perfectly into a 5×4 grid → optimal ratio = 1.000 |
| 02 | `02_mixed_rectangles` | 12 | 10.0 | 1×2, 2×3, 3×4 rects | 4 of each size; all tile exactly |
| 03 | `03_right_triangles_4x3` | 16 | 8.0 | right triangle legs 4×3 | Pairs of mirrored triangles tile perfectly |
| 04 | `04_hexagons_r2` | 12 | 14.0 | regular hexagon r=2 | Hexagons are hard to pack tightly |
| 05 | `05_stress_mixed_40pcs` | 40 | 15.0 | squares + rects + triangles + hexagons | Mixed shapes, larger search space |

### Metrics

| Metric | Formula | Interpretation |
|--------|---------|----------------|
| `lower_bound` | `total_piece_area / strip_width` | Area-based theoretical floor (ignores geometry) |
| `ratio` | `final_length / lower_bound` | 1.000 = optimal; lower is better |
| `efficiency` | `total_piece_area / (strip_width × final_length) × 100` | Area utilization % |

---

## Reference results

Baseline run on 2026-03-21 (debug build, Apple Silicon, 4 cores).

```
Case                             Pieces    Width   LowerBnd     Length    Effic%   Ratio  Time(ms)
-----------------------------------------------------------------------------------------------
01_identical_squares                 20      5.0      4.000      4.000    100.0%   1.000     4046
02_mixed_rectangles                  12     10.0      8.000      9.000     88.9%   1.125     2419
03_right_triangles_4x3               16      8.0     12.000     17.500     68.6%   1.458     2549
04_hexagons_r2                       12     14.0      8.908     13.864     64.3%   1.556     4276
05_stress_mixed_40pcs                40     15.0      7.732     11.432     67.6%   1.479     8347
```

### Observations

- **Case 01** achieves ratio 1.000 — the solver finds the theoretical optimum for identical unit squares.
- **Case 02** misses optimal by ~12.5% — rectangles with 45° rotations allowed leads to sub-optimal packing at this population/generation budget.
- **Cases 03–05** show the typical ~45–56% overhead of the area lower bound, which is expected since the lower bound ignores geometric constraints and is unachievable in practice for non-rectangular pieces.
- Debug timing is dominated by unoptimised code. Run with `-Doptimize=ReleaseFast` for realistic wall-clock comparison.

---

## Using results to evaluate improvements

When changing the GA parameters, packer, or chromosome encoding, re-run and compare:

1. **Ratio decreased** → packing quality improved.
2. **Time decreased, ratio unchanged** → efficiency win.
3. **Ratio increased** → regression; investigate before merging.

Case 01 is the canary: if its ratio rises above 1.000 something is broken (unit squares should always tile perfectly).
