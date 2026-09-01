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
const Change = message_mod.Change;

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
/// it, draw it, or hand it an message. What is kept is where each one ended up,
/// so a press can be turned back into the column it fell in.
const Views = struct {
    rects: std.ArrayList(Rect) = .empty,

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(self: *Views, allocator: std.mem.Allocator) void {
        self.rects.deinit(allocator);
    }

    /// Whatever it is given. How wide the columns are is a row's business; how
    /// tall they are is not, so it never asks for a height of its own.
    pub fn height(_: *const Views, _: *const Model) ?f32 {
        return null;
    }

    pub fn place(self: *Views, model: *const Model, rect: Rect) void {
        self.rect = rect;

        // Room for one more than there are, so `place` can fail to grow the
        // list and still leave every column somewhere sensible.
        self.rects.resize(model.allocator, model.columns.items.len) catch return;

        var left = rect.x;
        for (model.columns.items, self.rects.items, 1..) |file, *slot, nth| {
            const right = self.edge(model, nth);
            slot.* = .{ .x = left, .y = rect.y, .width = right - left, .height = rect.height };
            left = right;

            // The one thing layout writes back: what a column can show depends
            // on the room it has, which nothing knew when the message arrived.
            const column: TextView = .init(nth - 1, file, slot.*);
            column.settle(model);
        }
    }

    pub fn draw(self: *Views, model: *const Model, painter: *Painter) !void {
        for (model.columns.items, 0..) |file, which| {
            if (which >= self.rects.items.len) break;
            var column: TextView = .init(which, file, self.rects.items[which]);
            try column.draw(model, painter);
        }
    }

    pub fn update(self: *Views, model: *const Model, message: Message) !Change {
        switch (message) {
            .press => |what| {
                const which = self.over(what.at) orelse return .none;
                // Landing the caret or taking hold of the scrollbar both say
                // which column they are in, and both mean that column now has
                // the keyboard. A press that means neither -- an empty file --
                // still moves it.
                const asked = try self.tell(model, which, message);
                return switch (asked) {
                    .none => .{ .focus = which },
                    else => asked,
                };
            },
            // Only while something is held. A drag that wanders out of the
            // column it began in stays with it, and a pointer merely crossing
            // the window reaches no column at all -- which is what stops a
            // hover from dragging out a selection. Only the pointer is caught
            // that way: typing goes to the focused column even mid-drag.
            .move => return self.tell(model, model.holding orelse return .none, message),
            .release => return self.tell(model, model.holding orelse return .none, message),
            // Turns whatever it is under without deciding where typing lands.
            .wheel => |wheel| return self.tell(model, self.over(wheel.at) orelse return .none, message),
            else => return self.tell(model, model.focus, message),
        }
    }

    fn tell(self: *const Views, model: *const Model, which: usize, message: Message) !Change {
        if (which >= model.columns.items.len or which >= self.rects.items.len) return .none;
        const column: TextView = .init(which, model.columns.items[which], self.rects.items[which]);
        return column.update(model, message);
    }

    /// Where the nth column ends, counted from one. Worked out rather than
    /// remembered so that the columns always meet exactly, whatever the
    /// fractions, and so `place` and `over` cannot disagree.
    fn edge(self: *const Views, model: *const Model, nth: usize) f32 {
        const count = model.columns.items.len;
        if (count == 0) return self.rect.x;
        const share = self.rect.width * @as(f32, @floatFromInt(nth)) / @as(f32, @floatFromInt(count));
        return @round(self.rect.x + share);
    }

    fn over(self: *const Views, at: [2]f32) ?usize {
        for (self.rects.items, 0..) |rect, which| {
            if (rect.contains(at)) return which;
        }
        return null;
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

    pub fn place(self: *Workbench, model: *const Model, rect: Rect) void {
        self.stack.place(model, rect);
    }

    pub fn draw(self: *Workbench, model: *const Model, painter: *Painter) !void {
        try self.stack.draw(model, painter);
    }

    /// The bindings that are about which files are where, and then whatever is
    /// left over to the member with the keyboard.
    ///
    /// A tab is named by its place on the bar rather than by its path, so
    /// nothing here has to copy a string out of the model to say which file it
    /// means.
    pub fn update(self: *Workbench, model: *const Model, message: Message) !Change {
        switch (message) {
            .show => |which| return .{ .show = which },
            .split => |which| return .{ .split = which },
            .close => return .close,
            else => {},
        }

        const asked = try self.stack.update(model, message);

        // A press on the bar moves the keyboard to it, and nothing would move
        // it back: pressing a tab ends in showing that file, but pressing the
        // empty strip beside the tabs would leave typing going nowhere.
        switch (message) {
            .press => self.stack.focusOn(Views),
            else => {},
        }
        return asked;
    }
};
