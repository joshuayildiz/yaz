//! The files this window has open, and where each one is.
//!
//! A bar of tabs over a row of columns: the bar says how tall it is and the
//! columns take the rest. Every question about which files exist is answered
//! here, because they are all the same question asked of those two members --
//! which are on screen is which are in a column, which has the keyboard is
//! which column has it, and which have been changed is what their documents
//! say.
//!
//! It is also the only thing that takes a path from somewhere else. The finder
//! knows a file was picked and nothing about columns; this knows what to do
//! with a file and nothing about panels. `act` is where the two meet.

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
/// `model.columns`, and a column is made from it for as long as it takes to place
/// it, draw it, or hand it a message. Where each one ended up is kept on the
/// file it shows -- `OpenFile.rect` -- so a press can be turned back into the
/// column it fell in, and so `Model.update` can read it without a view.
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
