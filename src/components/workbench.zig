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

const HList = @import("./hlist.zig").HList;
const VTuple = @import("./vtuple.zig").VTuple;
const Tabs = @import("./tabs.zig").Tabs;
const TextView = @import("./text_view.zig").TextView;

/// Left to right, one per file on screen. A list rather than a tuple because
/// how many there are is not known until the program runs.
pub const Views = HList(TextView);

const Stack = VTuple(&.{ Tabs, Views });

pub const Workbench = struct {
    stack: Stack,

    /// True when a column has come or gone, or the keyboard has moved between
    /// them. Neither is inside a member, so nothing else can answer for it.
    dirty: bool = false,

    pub fn init(bar: Tabs, row: Views) Workbench {
        return .{ .stack = .init(.{ bar, row }) };
    }

    pub fn deinit(self: *Workbench, cx: *Context) void {
        self.stack.deinit(cx);
    }

    pub fn isDirty(self: *const Workbench) bool {
        return self.dirty or self.stack.isDirty();
    }

    pub fn setDirty(self: *Workbench, value: bool) void {
        self.dirty = value;
        self.stack.setDirty(value);
    }

    pub fn invalidate(self: *Workbench) void {
        self.stack.invalidate();
    }

    pub fn place(self: *Workbench, cx: *Context, rect: Rect) void {
        self.tell(cx);
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

        return self.act(cx, try self.stack.update(cx, event));
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
                self.dirty = true;
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
    fn tell(self: *Workbench, cx: *Context) void {
        const row = self.views();

        // Asked again every frame rather than kept in step, because a file
        // leaves a column without anything being told. Whether it has been
        // changed is not asked at all: the bar reads that off the file.
        for (cx.files.items) |file| file.shown = false;
        for (row.items.items) |*view| view.file.shown = true;

        self.tabs().showing(if (row.focused()) |view| view.file else null);
    }

    /// Puts `path` in front of the reader, in the column with the keyboard.
    ///
    /// A column already showing it is left alone rather than a second copy
    /// opened, which is both what one expects and the only way two views of one
    /// file cannot drift apart -- there is only one of each file, so they would
    /// be two views of the same caret.
    fn reveal(self: *Workbench, cx: *Context, path: []const u8) !void {
        const wanted = try cx.open(path);

        const row = self.views();
        for (row.items.items, 0..) |*view, which| {
            if (view.file != wanted) continue;
            row.focus = which;
            return;
        }

        const view = row.focused() orelse return;
        view.show(wanted);
    }

    /// Shows `path` and nothing else: every other column goes back to being
    /// open but not on screen.
    ///
    /// Choosing one of something is choosing it instead of the rest, which is
    /// what makes this the plain binding and `cmd+alt` the one that adds.
    fn showOnly(self: *Workbench, cx: *Context, path: []const u8) !void {
        const row = self.views();

        // Down to one column, keeping the one already showing it if there is
        // one. Nothing is closed: a column that goes stops pointing at a file,
        // and the file stays open.
        var column: usize = 0;
        while (row.items.items.len > 1) {
            const showing = row.items.items[column].file.path;
            if (showing != null and std.mem.eql(u8, showing.?, path)) {
                column += 1;
                continue;
            }
            _ = row.remove(column);
        }

        row.focus = 0;
        self.stack.focusOn(Views);
        // Points the one that is left at the file, or does nothing when it is
        // the one that was kept.
        try self.reveal(cx, path);
        self.dirty = true;
    }

    /// Puts the nth file on the bar beside what is already split, or takes it
    /// away again when it is already there.
    ///
    /// Taking one away is not closing it: the file stays on the bar with its
    /// caret where it was, so putting it back costs nothing. The last column
    /// cannot go -- something has to be there to type into.
    fn toggleSplit(self: *Workbench, cx: *Context, which: usize) !void {
        const row = self.views();
        const wanted = self.tabs().nth(cx, which) orelse return;

        for (row.items.items, 0..) |*view, column| {
            if (view.file != wanted) continue;

            if (row.items.items.len == 1) return;
            _ = row.remove(column);

            self.stack.focusOn(Views);
            self.dirty = true;
            return;
        }

        // Columns follow the bar's order, so one put back lands where it was
        // rather than on the end.
        const listed = cx.indexOf(wanted) orelse return;
        var at: usize = 0;
        for (row.items.items) |*view| {
            const seen = cx.indexOf(view.file) orelse continue;
            if (seen < listed) at += 1;
        }

        try row.insert(cx, at, .init(wanted));
        row.focus = at;
        self.stack.focusOn(Views);
        self.dirty = true;
    }

    /// Takes the file the focused column is showing out of the window and out
    /// of memory, and puts something else in the column. With nothing left on
    /// the bar the window goes too.
    ///
    /// The column takes the first file nothing else is showing, so closing
    /// walks back through what is open; when there is nothing left it goes
    /// empty, which is where a window with no file named starts.
    fn shut(self: *Workbench, cx: *Context) !void {
        const row = self.views();

        const view = row.focused() orelse return;
        const closing = view.file;

        // One fewer column to split into. The last one stays, because
        // something has to be there to type into.
        if (row.items.items.len > 1) {
            _ = row.remove(row.focus);
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
            view.show(next orelse try cx.blank());
        }

        cx.close(closing);

        // Nothing open is nothing to come back to. It is also where a window
        // that was never given a file starts, so cmd+W on one of those is a way
        // out rather than a keystroke that does nothing.
        for (cx.files.items) |file| {
            if (file.path != null) break;
        } else cx.running = false;

        self.dirty = true;
    }
};
