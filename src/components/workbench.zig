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

const context = @import("../context.zig");
const Context = context.Context;
const Position = context.Position;
const Document = @import("../document.zig").Document;

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
                const path = self.tabs().nth(which) orelse return .nothing;
                // Copied, because pointing a column at it frees the bar's copy
                // when the file it displaces is parked.
                const wanted = try cx.allocator.dupe(u8, path);
                defer cx.allocator.free(wanted);
                try self.showOnly(cx, wanted);
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
        const bar = self.tabs();
        const row = self.views();

        bar.showing(if (row.focused()) |view| view.path else null);

        // Which files have been changed, asked of the documents that hold them:
        // a document is either in a column or parked, and the bar lists both.
        // Which are on screen comes from the same walk, since that is what
        // being in a column means.
        bar.forgetColumns();
        for (row.items.items) |*view| {
            const named = view.path orelse continue;
            bar.columnShows(named);
            bar.mark(named, view.document.modified);
        }
        var resting = cx.parked.iterator();
        while (resting.next()) |entry| {
            bar.mark(entry.key_ptr.*, entry.value_ptr.document.modified);
        }
    }

    /// Puts `path` in front of the reader, in the column with the keyboard.
    ///
    /// A column already showing it is left alone rather than a second copy
    /// opened, which is both what one expects and the only way two views of one
    /// file cannot drift apart -- they share no document.
    fn reveal(self: *Workbench, cx: *Context, path: []const u8) !void {
        try self.tabs().opened(cx, path);

        const row = self.views();
        for (row.items.items, 0..) |*view, which| {
            const named = view.path orelse continue;
            if (!std.mem.eql(u8, named, path)) continue;

            row.focus = which;
            return;
        }

        const view = row.focused() orelse return;

        var document: Document = undefined;
        var was: ?Position = null;

        if (cx.unpark(path)) |resting| {
            // Looked at before: everything about it is still here.
            document = resting.document;
            was = resting.position;
        } else {
            // Through `read`, so a file picked here meets the same rules as one
            // named on the command line: the size limit, the UTF-8 check, and
            // CRLF turned into LF.
            var file = try cx.read(path);
            defer file.deinit(cx.allocator);
            document = try Document.init(cx.allocator, file.text);
        }
        errdefer document.deinit();

        try cx.park(try view.swap(cx, document, path, was));
    }

    /// Shows `path` and nothing else: every other column goes back to being
    /// open but not on screen.
    ///
    /// Choosing one of something is choosing it instead of the rest, which is
    /// what makes this the plain binding and `cmd+alt` the one that adds.
    fn showOnly(self: *Workbench, cx: *Context, path: []const u8) !void {
        const row = self.views();

        // Down to one column, keeping the one already showing it if there is
        // one. Whatever is taken away is parked, not closed.
        var column: usize = 0;
        while (row.items.items.len > 1) {
            const named = row.items.items[column].path;
            if (named != null and std.mem.eql(u8, named.?, path)) {
                column += 1;
                continue;
            }
            var gone = row.remove(column);
            try cx.park(gone.retire());
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
    /// Taking one away is not closing it: the file stays on the bar and its
    /// document is parked, so putting it back costs nothing. The last column
    /// cannot go -- something has to be there to type into.
    fn toggleSplit(self: *Workbench, cx: *Context, which: usize) !void {
        const row = self.views();
        const bar = self.tabs();

        const path = bar.nth(which) orelse return;

        for (row.items.items, 0..) |*view, column| {
            const named = view.path orelse continue;
            if (!std.mem.eql(u8, named, path)) continue;

            if (row.items.items.len == 1) return;
            var gone = row.remove(column);
            try cx.park(gone.retire());

            self.stack.focusOn(Views);
            self.dirty = true;
            return;
        }

        // Columns follow the bar's order, so one put back lands where it was
        // rather than on the end.
        var at: usize = 0;
        for (row.items.items) |*view| {
            const named = view.path orelse continue;
            const listed = bar.indexOf(named) orelse continue;
            if (listed < which) at += 1;
        }

        var document: Document = undefined;
        var was: ?Position = null;
        if (cx.unpark(path)) |resting| {
            document = resting.document;
            was = resting.position;
        } else {
            var file = try cx.read(path);
            defer file.deinit(cx.allocator);
            document = try Document.init(cx.allocator, file.text);
        }
        errdefer document.deinit();

        try row.insert(cx, at, try TextView.hold(cx.allocator, document, path, was));
        row.focus = at;
        self.stack.focusOn(Views);
        self.dirty = true;
    }

    /// Takes the file the focused column is showing off the bar and out of
    /// memory, and puts something else in the column. With nothing left on the
    /// bar the window goes too.
    ///
    /// The column takes the first file nothing is showing, so closing walks
    /// back through what is open; when there is nothing left it goes empty,
    /// which is where a window with no file named starts.
    fn shut(self: *Workbench, cx: *Context) !void {
        const row = self.views();
        const bar = self.tabs();

        // A document nobody named has no tab and so nothing to close, which is
        // not the same as nothing to do: the window still goes if that leaves
        // the bar empty.
        close: {
            const view = row.focused() orelse break :close;
            const closing = view.path orelse break :close;

            bar.close(cx, closing);

            // One fewer split. The last one stays, because something has to be
            // there to type into while anything is open at all.
            if (row.items.items.len > 1) {
                var gone = row.remove(row.focus);
                gone.deinit(cx);
                break :close;
            }

            // Being the only one, it takes the first file nothing else is
            // showing instead, or goes empty when there is none.
            var document: Document = undefined;
            var was: ?Position = null;
            var path: ?[]const u8 = null;
            for (bar.paths.items) |listed| {
                const resting = cx.unpark(listed) orelse continue;
                document = resting.document;
                was = resting.position;
                path = listed;
                break;
            }
            if (path == null) document = try Document.init(cx.allocator, "");
            errdefer document.deinit();

            var retired = try view.swap(cx, document, path, was);

            // Not parked: closing is the one thing that means a document is
            // finished with.
            if (retired.path) |named| cx.allocator.free(named);
            retired.document.deinit();
        }

        // Nothing open is nothing to come back to. It is also where a window
        // that was never given a file starts, so cmd+W on one of those is a way
        // out rather than a keystroke that does nothing.
        if (bar.paths.items.len == 0) cx.running = false;
        self.dirty = true;
    }
};
