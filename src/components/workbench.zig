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

/// Left to right, one per file on screen.
///
/// Which files those are is not this to decide or to remember: it is
/// `model.columns`. It gives each its share of the width and writes the rect onto
/// the file it shows -- `OpenFile.rect` -- so a press can be turned back into the
/// column it fell in, and `Model.resolve` can read it without a view.
const Views = struct {
    pub fn deinit(_: *Views, _: std.mem.Allocator) void {}

    /// Whatever it is given. How wide the columns are is a row's business; how
    /// tall they are is not, so it never asks for a height of its own.
    pub fn height(_: *const Views, _: *const Model) ?f32 {
        return null;
    }

    /// Divides the room into a column per file on screen, writing each column's
    /// rect onto the file it shows -- a file is in at most one column, so there
    /// is one rect, and keeping it there is what lets `Model.update` reach it
    /// without a view. Each edge is rounded off the running width so the columns
    /// meet exactly and `Model.columnAt` cannot disagree with where they were
    /// drawn.
    pub fn place(_: *Views, model: *Model, rect: Rect) !void {
        const count: f32 = @floatFromInt(model.columns.items.len);
        var left = rect.x;
        for (model.columns.items, 1..) |file, nth| {
            const right = @round(rect.x + rect.width * @as(f32, @floatFromInt(nth)) / count);
            file.rect = .{ .x = left, .y = rect.y, .width = right - left, .height = rect.height };
            left = right;

            // Layout is the one thing that writes back to a file: what a column
            // can show depends on the room it has, unknown when a message arrived.
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
