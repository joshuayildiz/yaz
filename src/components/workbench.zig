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
//! with a file and nothing about panels. `offer` is where the two meet.

const std = @import("std");

const Context = @import("../context.zig").Context;
const OpenFile = @import("../open_file.zig").OpenFile;

const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const Intent = event_mod.Intent;

const painter_mod = @import("../painter.zig");
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const VTuple = @import("./vtuple.zig").VTuple;
const Tabs = @import("./tabs.zig").Tabs;
const TextView = @import("./text_view.zig").TextView;

/// Left to right, one per file on screen.
///
/// Which files those are is not this to decide or to remember: it is
/// `cx.columns`, and a column is made from it for as long as it takes to place
/// it, draw it, or hand it an event. What is kept is where each one ended up,
/// so a press can be turned back into the column it fell in.
pub const Views = struct {
    rects: std.ArrayList(Rect) = .empty,

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(self: *Views, cx: *Context) void {
        self.rects.deinit(cx.allocator);
    }

    /// Nothing shaped is kept here: what a column draws belongs to its file,
    /// and the context drops that for every file it holds.
    pub fn invalidate(_: *Views) void {}

    /// Whatever it is given. How wide the columns are is a row's business; how
    /// tall they are is not, so it never asks for a height of its own.
    pub fn height(_: *const Views, _: *Context) ?f32 {
        return null;
    }

    pub fn place(self: *Views, cx: *Context, rect: Rect) void {
        self.rect = rect;

        // Room for one more than there are, so `place` can fail to grow the
        // list and still leave every column somewhere sensible.
        self.rects.resize(cx.allocator, cx.columns.items.len) catch return;

        var left = rect.x;
        for (cx.columns.items, self.rects.items, 1..) |file, *slot, nth| {
            const right = self.edge(cx, nth);
            slot.* = .{ .x = left, .y = rect.y, .width = right - left, .height = rect.height };
            left = right;

            var column: TextView = .init(file, slot.*);
            column.place(cx, slot.*);
        }
    }

    pub fn draw(self: *Views, cx: *Context, painter: *Painter) !void {
        for (cx.columns.items, 0..) |file, which| {
            if (which >= self.rects.items.len) break;
            var column: TextView = .init(file, self.rects.items[which]);
            try column.draw(cx, painter);
        }
    }

    pub fn update(self: *Views, cx: *Context, event: Event) !Intent {
        switch (event) {
            .press => |at| {
                const which = self.over(at) orelse return .nothing;
                if (cx.focus != which) {
                    cx.focus = which;
                    cx.changed();
                }
                cx.holding = which;
                return self.tell(cx, which, event);
            },
            // Held, so a drag that wanders out of the column it began in stays
            // with it. Only the pointer is caught that way: typing goes to the
            // focused column even mid-drag.
            .move => |at| return self.tell(cx, cx.holding orelse self.over(at) orelse return .nothing, event),
            .release => {
                const which = cx.holding orelse return .nothing;
                cx.holding = null;
                return self.tell(cx, which, event);
            },
            // Turns whatever it is under without deciding where typing lands.
            .wheel => |wheel| return self.tell(cx, self.over(wheel.at) orelse return .nothing, event),
            else => return self.tell(cx, cx.focus, event),
        }
    }

    fn tell(self: *Views, cx: *Context, which: usize, event: Event) !Intent {
        if (which >= cx.columns.items.len or which >= self.rects.items.len) return .nothing;
        var column: TextView = .init(cx.columns.items[which], self.rects.items[which]);
        return column.update(cx, event);
    }

    /// Where the nth column ends, counted from one. Worked out rather than
    /// remembered so that the columns always meet exactly, whatever the
    /// fractions, and so `place` and `over` cannot disagree.
    fn edge(self: *const Views, cx: *Context, nth: usize) f32 {
        const count = cx.columns.items.len;
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
    stack: Stack,

    pub fn init(bar: Tabs, row: Views) Workbench {
        var self: Workbench = .{ .stack = .init(.{ bar, row }) };
        // The columns have the keyboard from the moment there is a window. A
        // bar is something to press, not something to type into, and the first
        // member of a column would otherwise have it by default.
        self.stack.focusOn(Views);
        return self;
    }

    pub fn deinit(self: *Workbench, cx: *Context) void {
        self.stack.deinit(cx);
    }

    pub fn invalidate(self: *Workbench) void {
        self.stack.invalidate();
    }

    pub fn place(self: *Workbench, cx: *Context, rect: Rect) void {
        self.stack.place(cx, rect);
    }

    pub fn draw(self: *Workbench, cx: *Context, painter: *Painter) !void {
        try self.stack.draw(cx, painter);
    }

    /// The bindings that are about which files are where, and then whatever is
    /// left over to the member with the keyboard.
    pub fn update(self: *Workbench, cx: *Context, event: Event) !Intent {
        switch (event) {
            .tab => |which| {
                const file = self.tabs().nth(cx, which) orelse return .nothing;
                try self.showOnly(cx, file.path orelse return .nothing);
                return .nothing;
            },
            .split => |which| {
                try self.toggleSplit(cx, which);
                return .nothing;
            },
            .close => {
                try self.shut(cx);
                return .nothing;
            },
            else => {},
        }

        const asked = try self.stack.update(cx, event);

        // A press on the bar moves the keyboard to it, and nothing would move
        // it back: pressing a tab ends in `showOnly`, but pressing the empty
        // strip beside the tabs would leave typing going nowhere.
        switch (event) {
            .press => self.stack.focusOn(Views),
            else => {},
        }

        return self.act(cx, asked);
    }

    /// A path from something that is not one of its members -- the finder, in
    /// front of it. Taking one is also the end of whatever asked, so this says
    /// so; see `ZTuple.pass`.
    pub fn offer(self: *Workbench, cx: *Context, intent: Intent) !Intent {
        switch (intent) {
            .open, .only => {
                _ = try self.act(cx, intent);
                return .dismiss;
            },
            else => return intent,
        }
    }

    /// What a path means, wherever it came from. Anything else is not this to
    /// answer and goes back the way it came.
    fn act(self: *Workbench, cx: *Context, intent: Intent) !Intent {
        switch (intent) {
            .open => |path| {
                defer cx.allocator.free(path);
                try self.reveal(cx, path);

                // Choosing a file is choosing to read it, so the keyboard
                // follows it into the column it landed in -- wherever the press
                // that chose it happened.
                self.stack.focusOn(Views);
                cx.changed();
                return .nothing;
            },
            .only => |path| {
                defer cx.allocator.free(path);
                try self.showOnly(cx, path);
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
    fn reveal(_: *Workbench, cx: *Context, path: []const u8) !void {
        const wanted = try cx.open(path);

        if (cx.columnOf(wanted)) |which| {
            cx.focus = which;
        } else if (cx.focus < cx.columns.items.len) {
            cx.columns.items[cx.focus] = wanted;
        } else {
            try cx.columns.append(cx.allocator, wanted);
            cx.focus = cx.columns.items.len - 1;
        }
        cx.changed();
    }

    /// Shows `path` and nothing else: every other column goes back to being
    /// open but not on screen.
    ///
    /// Choosing one of something is choosing it instead of the rest, which is
    /// what makes this the plain binding and `cmd+alt` the one that adds.
    fn showOnly(self: *Workbench, cx: *Context, path: []const u8) !void {
        const wanted = try cx.open(path);

        cx.columns.clearRetainingCapacity();
        try cx.columns.append(cx.allocator, wanted);
        cx.focus = 0;
        self.stack.focusOn(Views);
        cx.changed();
    }

    /// Puts the nth file on the bar beside what is already split, or takes it
    /// away again when it is already there.
    ///
    /// Taking one away is not closing it: the file stays on the bar with its
    /// caret where it was, so putting it back costs nothing. The last column
    /// cannot go -- something has to be there to type into.
    fn toggleSplit(self: *Workbench, cx: *Context, which: usize) !void {
        const wanted = self.tabs().nth(cx, which) orelse return;

        if (cx.columnOf(wanted)) |column| {
            if (cx.columns.items.len == 1) return;
            _ = cx.columns.orderedRemove(column);
            if (cx.focus >= cx.columns.items.len) cx.focus = cx.columns.items.len - 1;
        } else {
            // Columns follow the bar's order, so one put back lands where it
            // was rather than on the end.
            const listed = cx.indexOf(wanted) orelse return;
            var at: usize = 0;
            for (cx.columns.items) |shown| {
                const seen = cx.indexOf(shown) orelse continue;
                if (seen < listed) at += 1;
            }
            try cx.columns.insert(cx.allocator, at, wanted);
            cx.focus = at;
        }

        self.stack.focusOn(Views);
        cx.changed();
    }

    /// Takes the file the focused column is showing out of the window and out
    /// of memory, and puts something else in the column. With nothing left on
    /// the bar the window goes too.
    ///
    /// The column takes the first file nothing else is showing, so closing
    /// walks back through what is open; when there is nothing left it goes
    /// empty, which is where a window with no file named starts.
    fn shut(_: *Workbench, cx: *Context) !void {
        const closing = cx.showing() orelse return;

        // One fewer column to split into. The last one stays, because
        // something has to be there to type into.
        if (cx.columns.items.len > 1) {
            _ = cx.columns.orderedRemove(cx.focus);
            if (cx.focus >= cx.columns.items.len) cx.focus = cx.columns.items.len - 1;
        } else {
            // Being the only one, it takes the first file nothing else is
            // showing instead, or a blank one when there is none.
            var next: ?*OpenFile = null;
            for (cx.files.items) |file| {
                if (file != closing and file.path != null) {
                    next = file;
                    break;
                }
            }
            cx.columns.items[0] = next orelse try cx.blank();
        }

        cx.close(closing);

        // Nothing open is nothing to come back to. It is also where a window
        // that was never given a file starts, so cmd+W on one of those is a way
        // out rather than a keystroke that does nothing.
        for (cx.files.items) |file| {
            if (file.path != null) break;
        } else cx.running = false;

        cx.changed();
    }
};
