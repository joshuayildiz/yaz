//! The files on screen: a bar of tabs over a row of columns, the bar as tall as
//! it asks and the columns taking the rest.
//!
//! Layout and drawing, nothing more. Which files exist, which are on screen and
//! which has the keyboard are the model's; this reads `model.columns`, gives each
//! column its share of the width, and writes each one's rect onto the file it
//! shows so `Model.resolve` can turn a press back into it.

const std = @import("std");

const Model = @import("../model.zig").Model;

const painter_mod = @import("../painter.zig");
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const VTuple = @import("./vtuple.zig").VTuple;
const Tabs = @import("./tabs.zig").Tabs;
const TextView = @import("./text_view.zig").TextView;

/// The row of columns, one per file on screen.
const Views = struct {
    pub fn deinit(_: *Views, _: std.mem.Allocator) void {}

    /// Null: the columns take whatever the bar leaves.
    pub fn height(_: *const Views, _: *const Model) ?f32 {
        return null;
    }

    /// Each edge is rounded off the running width so the columns meet exactly and
    /// `Model.columnAt` cannot disagree with where they were drawn.
    pub fn place(_: *Views, model: *Model, rect: Rect) !void {
        const count: f32 = @floatFromInt(model.columns.items.len);
        var left = rect.x;
        for (model.columns.items, 1..) |file, nth| {
            const right = @round(rect.x + rect.width * @as(f32, @floatFromInt(nth)) / count);
            file.rect = .{ .x = left, .y = rect.y, .width = right - left, .height = rect.height };
            left = right;

            // settle fits the file to the room, which nothing knew until now.
            const column: TextView = .init(nth - 1, file, file.rect);
            column.settle(model);
        }
    }

    pub fn draw(_: *Views, model: *const Model, painter: *Painter) !void {
        for (model.columns.items, 0..) |file, which| {
            var column: TextView = .init(which, file, file.rect);
            try column.draw(model, painter);
        }
    }
};

/// The bar of tabs over the row of columns, and nothing but the two stacked:
/// which one a pointer fell in is `Model.resolve`'s to work out from the rects
/// they leave, so this only has to lay them out and draw them.
pub const Workbench = VTuple(&.{ Tabs, Views });
