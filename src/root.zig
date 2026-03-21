//! Bin Packing Solver - A high-performance 2D nesting library using genetic algorithms.
const std = @import("std");

// Internal modules (not exported)
const vec2 = @import("vec2.zig");
const polygon = @import("polygon.zig");
const placed_item = @import("placed_item.zig");
const piece_constraints = @import("piece_constraints.zig");
const rotation_constraints = @import("rotation_constraints.zig");
const nesting_result = @import("nesting_result.zig");
const nesting = @import("nesting.zig");
const helpers = @import("helpers.zig");
const nfp = @import("nfp.zig");

// Public API - Types
pub const Vec2 = vec2.Vec2;
pub const Polygon = polygon.Polygon;
pub const PlacedItem = placed_item.PlacedItem;
pub const NestingResult = nesting_result.NestingResult;
pub const PieceConstraints = piece_constraints.PieceConstraints;
pub const RotationConstraints = rotation_constraints.RotationConstraints;

// Public API - Types
pub const NestingConfig = nesting.NestingConfig;
pub const NestingError = nesting.NestingError;

// Public API - Functions
pub const performNesting = nesting.performNesting;
pub const generateRandomConvex = helpers.generateRandomConvex;
pub const generateRandomConcave = helpers.generateRandomConcave;
pub const exportToSVG = helpers.exportToSVG;
pub const computeNFP = nfp.computeNFP;
pub const pointInPolygon = nfp.pointInPolygon;
pub const checkOverlapNFP = nfp.checkOverlapNFP;
