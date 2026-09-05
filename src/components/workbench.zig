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
const OpenFile = @import("../open_file.zig").OpenFile;

const message_mod = @import("../message.zig");
const Message = message_mod.Message;

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
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(_: *Views, _: std.mem.Allocator) void {}

    /// Whatever it is given. How wide the columns are is a row's business; how
    /// tall they are is not, so it never asks for a height of its own.
    pub fn height(_: *const Views, _: *const Model) ?f32 {
        return null;
    }

    pub fn place(self: *Views, model: *Model, rect: Rect) !void {
        self.rect = rect;

        var left = rect.x;
        for (model.columns.items, 1..) |file, nth| {
            const right = self.edge(model, nth);
            // Written onto the file it shows: a file is in at most one column, so
            // there is one rect, and keeping it there is what lets `update` reach
            // it without a view.
            file.rect = .{ .x = left, .y = rect.y, .width = right - left, .height = rect.height };
            left = right;

            // The one thing layout writes back: what a column can show depends
            // on the room it has, which nothing knew when the message arrived.
            const column: TextView = .init(nth - 1, file, file.rect);
            column.settle(model);
        }
    }

    pub fn draw(self: *Views, model: *const Model, painter: *Painter) !void {
        _ = self;
        for (model.columns.items, 0..) |file, which| {
            var column: TextView = .init(which, file, file.rect);
            try column.draw(model, painter);
        }
    }

    /// Where the nth column ends, counted from one. Worked out rather than
    /// remembered so that the columns always meet exactly, whatever the
    /// fractions, and so `place` and `Model.columnAt` cannot disagree.
    fn edge(self: *const Views, model: *const Model, nth: usize) f32 {
        const count = model.columns.items.len;
        if (count == 0) return self.rect.x;
        const share = self.rect.width * @as(f32, @floatFromInt(nth)) / @as(f32, @floatFromInt(count));
        return @round(self.rect.x + share);
    }
};

const Stack = VTuple(&.{ Tabs, Views });

pub const Workbench = struct {
    /// The columns have the keyboard from the moment there is a window. A bar
    /// is something to press, not something to type into, and the first member
    /// of a column would otherwise have it by default.
    stack: Stack = stack: {
        var built: Stack = .init(.{ .{}, .{} });
        built.focusOn(Views);
        break :stack built;
    },

    pub fn deinit(self: *Workbench, allocator: std.mem.Allocator) void {
        self.stack.deinit(allocator);
    }

    pub fn place(self: *Workbench, model: *Model, rect: Rect) !void {
        try self.stack.place(model, rect);
    }

    pub fn draw(self: *Workbench, model: *const Model, painter: *Painter) !void {
        try self.stack.draw(model, painter);
    }
};
