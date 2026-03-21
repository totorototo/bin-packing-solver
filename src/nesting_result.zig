const std = @import("std");
const PlacedItem = @import("placed_item.zig").PlacedItem;

pub const NestingResult = struct {
    placed_items: std.ArrayList(PlacedItem),
    best_fitness: f32,
    efficiency: f32,
    final_length: f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *NestingResult) void {
        for (self.placed_items.items) |*item| {
            item.poly.deinit(self.allocator);
        }
        self.placed_items.deinit(self.allocator);
    }
};
