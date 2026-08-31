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
const Intent = message_mod.Intent;

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
pub const Views = struct {
    rects: std.ArrayList(Rect) = .empty,

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(self: *Views, model: *Model) void {
        self.rects.deinit(model.allocator);
    }

    /// Nothing shaped is kept here: what a column draws belongs to its file,
    /// and the context drops that for every file it holds.
    pub fn invalidate(_: *Views) void {}

    /// Whatever it is given. How wide the columns are is a row's business; how
    /// tall they are is not, so it never asks for a height of its own.
    pub fn height(_: *const Views, _: *Model) ?f32 {
        return null;
    }

    pub fn place(self: *Views, model: *Model, rect: Rect) void {
        self.rect = rect;

        // Room for one more than there are, so `place` can fail to grow the
        // list and still leave every column somewhere sensible.
        self.rects.resize(model.allocator, model.columns.items.len) catch return;

        var left = rect.x;
        for (model.columns.items, self.rects.items, 1..) |file, *slot, nth| {
            const right = self.edge(model, nth);
            slot.* = .{ .x = left, .y = rect.y, .width = right - left, .height = rect.height };
            left = right;

            var column: TextView = .init(file, slot.*);
            column.place(model, slot.*);
        }
    }

    pub fn draw(self: *Views, model: *Model, painter: *Painter) !void {
        for (model.columns.items, 0..) |file, which| {
            if (which >= self.rects.items.len) break;
            var column: TextView = .init(file, self.rects.items[which]);
            try column.draw(model, painter);
        }
    }

    pub fn update(self: *Views, model: *Model, message: Message) !Intent {
        switch (message) {
            .press => |at| {
                const which = self.over(at) orelse return .nothing;
                if (model.focus != which) {
                    model.focus = which;
                    model.changed();
                }
                model.holding = which;
                return self.tell(model, which, message);
            },
            // Held, so a drag that wanders out of the column it began in stays
            // with it. Only the pointer is caught that way: typing goes to the
            // focused column even mid-drag.
            .move => |at| return self.tell(model, model.holding orelse self.over(at) orelse return .nothing, message),
            .release => {
                const which = model.holding orelse return .nothing;
                model.holding = null;
                return self.tell(model, which, message);
            },
            // Turns whatever it is under without deciding where typing lands.
            .wheel => |wheel| return self.tell(model, self.over(wheel.at) orelse return .nothing, message),
            else => return self.tell(model, model.focus, message),
        }
    }

    fn tell(self: *Views, model: *Model, which: usize, message: Message) !Intent {
        if (which >= model.columns.items.len or which >= self.rects.items.len) return .nothing;
        var column: TextView = .init(model.columns.items[which], self.rects.items[which]);
        return column.update(model, message);
    }

    /// Where the nth column ends, counted from one. Worked out rather than
    /// remembered so that the columns always meet exactly, whatever the
    /// fractions, and so `place` and `over` cannot disagree.
    fn edge(self: *const Views, model: *Model, nth: usize) f32 {
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

    pub fn deinit(self: *Workbench, model: *Model) void {
        self.stack.deinit(model);
    }

    pub fn invalidate(self: *Workbench) void {
        self.stack.invalidate();
    }

    pub fn place(self: *Workbench, model: *Model, rect: Rect) void {
        self.stack.place(model, rect);
    }

    pub fn draw(self: *Workbench, model: *Model, painter: *Painter) !void {
        try self.stack.draw(model, painter);
    }

    /// The bindings that are about which files are where, and then whatever is
    /// left over to the member with the keyboard.
    pub fn update(self: *Workbench, model: *Model, message: Message) !Intent {
        switch (message) {
            .tab => |which| {
                const file = self.tabs().nth(model, which) orelse return .nothing;
                try self.showOnly(model, file.path orelse return .nothing);
                return .nothing;
            },
            .split => |which| {
                try self.toggleSplit(model, which);
                return .nothing;
            },
            .close => {
                try self.shut(model);
                return .nothing;
            },
            else => {},
        }

        const asked = try self.stack.update(model, message);

        // A press on the bar moves the keyboard to it, and nothing would move
        // it back: pressing a tab ends in `showOnly`, but pressing the empty
        // strip beside the tabs would leave typing going nowhere.
        switch (message) {
            .press => self.stack.focusOn(Views),
            else => {},
        }

        return self.act(model, asked);
    }

    /// What a path means, wherever it came from. Anything else is not this to
    /// answer and goes back the way it came.
    pub fn act(self: *Workbench, model: *Model, intent: Intent) !Intent {
        switch (intent) {
            .open => |path| {
                defer model.allocator.free(path);
                try self.reveal(model, path);

                // Choosing a file is choosing to read it, so the keyboard
                // follows it into the column it landed in -- wherever the press
                // that chose it happened.
                self.stack.focusOn(Views);
                model.changed();
                return .nothing;
            },
            .only => |path| {
                defer model.allocator.free(path);
                try self.showOnly(model, path);
                return .nothing;
            },
            else => return intent,
        }
    }

    fn tabs(self: *Workbench) *Tabs {
        return self.stack.get(Tabs);
    }

    fn views(self: *Workbench) *Views {
        return self.stack.get(Views);
    }

    /// What the bar says, asked of the columns rather than remembered, so it
    /// cannot disagree with what is on screen -- a press that moves the
    /// keyboard to another column moves the tab in front with it, and nothing
    /// had to tell the bar so.
    /// Puts `path` in front of the reader, in the column with the keyboard.
    ///
    /// A column already showing it is left alone rather than a second copy
    /// opened, which is both what one expects and the only way two columns
    /// cannot drift apart -- there is one of each file, so they would be two
    /// views of the same caret.
    fn reveal(_: *Workbench, model: *Model, path: []const u8) !void {
        const wanted = try model.open(path);

        if (model.columnOf(wanted)) |which| {
            model.focus = which;
        } else if (model.focus < model.columns.items.len) {
            model.columns.items[model.focus] = wanted;
        } else {
            try model.columns.append(model.allocator, wanted);
            model.focus = model.columns.items.len - 1;
        }
        model.changed();
    }

    /// Shows `path` and nothing else: every other column goes back to being
    /// open but not on screen.
    ///
    /// Choosing one of something is choosing it instead of the rest, which is
    /// what makes this the plain binding and `cmd+alt` the one that adds.
    fn showOnly(self: *Workbench, model: *Model, path: []const u8) !void {
        const wanted = try model.open(path);

        model.columns.clearRetainingCapacity();
        try model.columns.append(model.allocator, wanted);
        model.focus = 0;
        self.stack.focusOn(Views);
        model.changed();
    }

    /// Puts the nth file on the bar beside what is already split, or takes it
    /// away again when it is already there.
    ///
    /// Taking one away is not closing it: the file stays on the bar with its
    /// caret where it was, so putting it back costs nothing. The last column
    /// cannot go -- something has to be there to type into.
    fn toggleSplit(self: *Workbench, model: *Model, which: usize) !void {
        const wanted = self.tabs().nth(model, which) orelse return;

        if (model.columnOf(wanted)) |column| {
            if (model.columns.items.len == 1) return;
            _ = model.columns.orderedRemove(column);
            if (model.focus >= model.columns.items.len) model.focus = model.columns.items.len - 1;
        } else {
            // Columns follow the bar's order, so one put back lands where it
            // was rather than on the end.
            const listed = model.indexOf(wanted) orelse return;
            var at: usize = 0;
            for (model.columns.items) |shown| {
                const seen = model.indexOf(shown) orelse continue;
                if (seen < listed) at += 1;
            }
            try model.columns.insert(model.allocator, at, wanted);
            model.focus = at;
        }

        self.stack.focusOn(Views);
        model.changed();
    }

    /// Takes the file the focused column is showing out of the window and out
    /// of memory, and puts something else in the column. With nothing left on
    /// the bar the window goes too.
    ///
    /// The column takes the first file nothing else is showing, so closing
    /// walks back through what is open; when there is nothing left it goes
    /// empty, which is where a window with no file named starts.
    fn shut(_: *Workbench, model: *Model) !void {
        const closing = model.showing() orelse return;

        // One fewer column to split into. The last one stays, because
        // something has to be there to type into.
        if (model.columns.items.len > 1) {
            _ = model.columns.orderedRemove(model.focus);
            if (model.focus >= model.columns.items.len) model.focus = model.columns.items.len - 1;
        } else {
            // Being the only one, it takes the first file nothing else is
            // showing instead, or a blank one when there is none.
            var next: ?*OpenFile = null;
            for (model.files.items) |file| {
                if (file != closing and file.path != null) {
                    next = file;
                    break;
                }
            }
            model.columns.items[0] = next orelse try model.blank();
        }

        model.close(closing);

        // Nothing open is nothing to come back to. It is also where a window
        // that was never given a file starts, so cmd+W on one of those is a way
        // out rather than a keystroke that does nothing.
        for (model.files.items) |file| {
            if (file.path != null) break;
        } else model.running = false;

        model.changed();
    }
};
