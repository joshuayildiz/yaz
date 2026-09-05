//! The state the window is showing, and the only thing that outlives a frame.
//! Components keep almost nothing between frames -- what files are open, which
//! are on screen, where each caret and rect is -- so drawing and resolving a
//! click both come down to reading this. Handed to `place` and `draw` rather
//! than stored, so nothing keeps a second copy of the allocator to drift.

const std = @import("std");

const GlyphAtlas = @import("./glyph_atlas.zig").GlyphAtlas;
const LineLayout = @import("./glyph_atlas.zig").LineLayout;
const Rect = @import("./painter.zig").Rect;
const open_file = @import("./open_file.zig");
const OpenFile = open_file.OpenFile;
const Span = open_file.Span;
const tools = @import("./tools.zig");
const sdl = @import("./sdl.zig");
const c = sdl.c;
const fff = @import("./fff.zig");
const message = @import("./message.zig");
const Message = message.Message;
const Effect = message.Effect;
const TextView = @import("./components/text_view.zig").TextView;
const Tree = @import("./components/tree.zig").Tree;

/// What still costs per line of the file, not per line on screen, is the layout
/// cache: a 64-byte entry for each, and the line index behind it.
const file_limit = 1 << 20;

pub const visible_matches = 12;

/// The file finder, while it is open -- null is the whole of what "closed"
/// means. It holds no listing of its own; the index is the library's.
pub const Finding = struct {
    typed: std.ArrayList(u8) = .empty,

    /// Owned: the paths point into it, so it is freed when the query changes.
    found: ?fff.Matches = null,

    /// Re-read from every search, since the watcher moves it while the panel is up.
    files: u32 = 0,

    selected: usize = 0,
    top: usize = 0,

    pub fn count(self: *const Finding) usize {
        const found = self.found orelse return 0;
        return found.count;
    }

    /// Which set of matches these are, so anything caching what it drew of them
    /// can tell a new search from the same one.
    pub fn token(self: *const Finding) ?*anyopaque {
        const found = self.found orelse return null;
        return found.handle;
    }

    pub fn path(self: *const Finding, nth: usize) ?[]const u8 {
        const found = self.found orelse return null;
        return found.path(@intCast(nth));
    }

    fn chosen(self: *const Finding) ?[]const u8 {
        return self.path(self.selected);
    }
};

/// One line of the folded tree: `path` is borrowed from `Sidebar.paths`.
pub const Row = struct {
    path: []const u8,
    name: []const u8,
    depth: u16,
    is_dir: bool,
};

/// The sidebar tree, whether open or not. It holds its own listing rather than
/// the finder's, which is ranked and cut to a screenful -- the wrong shape for a
/// tree -- so this is the whole of what the index holds, sorted by path.
pub const Sidebar = struct {
    open: bool = false,

    /// Owned here: the listing it was read from is let go of at once.
    paths: std.ArrayList([]const u8) = .empty,

    /// A folder not in here is closed. Keys are owned, since the path they came
    /// from is a row that is rebuilt.
    expanded: std.StringHashMapUnmanaged(void) = .empty,

    /// Clamped by the view, which is the only thing that knows how many rows
    /// there are and how tall it is.
    scroll: f32 = 0,

    /// Bumped when `paths` or `expanded` changes, so the fold and its glyphs are
    /// known stale without comparing them.
    revision: u32 = 0,

    /// Written by `place`.
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    /// The listing folded into a hierarchy and a shaped line for each, parallel.
    /// `place` folds them when `built` falls behind `revision` and shapes the
    /// ones on screen.
    rows: std.ArrayList(Row) = .empty,
    layouts: std.ArrayList(LineLayout) = .empty,
    built: ?u32 = null,

    chevron_open: LineLayout = .{},
    chevron_shut: LineLayout = .{},

    /// Keeps the open folders: closing the panel need not forget them, and
    /// re-reading the tree must not leak the last read.
    fn clearPaths(self: *Sidebar, allocator: std.mem.Allocator) void {
        for (self.paths.items) |path| allocator.free(path);
        self.paths.clearRetainingCapacity();
    }

    fn deinit(self: *Sidebar, allocator: std.mem.Allocator) void {
        self.clearPaths(allocator);
        self.paths.deinit(allocator);
        var keys = self.expanded.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        self.expanded.deinit(allocator);

        for (self.layouts.items) |*layout| layout.deinit(allocator);
        self.layouts.deinit(allocator);
        self.rows.deinit(allocator);
        self.chevron_open.deinit(allocator);
        self.chevron_shut.deinit(allocator);
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Not const: shaping a line nobody has shaped before writes here, so drawing
    /// a file for the first time does. Undefined until `run` has a window.
    atlas: *GlyphAtlas = undefined,

    /// The tab bar's band and the unsaved-mark glyph every tab shares, written by
    /// `place`, so `update` can turn a press into the tab it fell on. Each tab's
    /// own rect is on the file it names, `OpenFile.tab_rect`.
    tabs_rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    tab_bullet: LineLayout = .{},

    /// The file a save dialog is open for. Checked against the open files rather
    /// than trusted, since the answer arrives long after and cmd+W can have
    /// closed the file in between.
    naming: ?*OpenFile = null,

    /// Owned here and nowhere else; boxed, since the bar and the columns keep
    /// pointers into this and the list moves as it grows. A column points at one
    /// rather than holding it, so a file no column shows is just open and unseen.
    files: std.ArrayList(*OpenFile) = .empty,

    /// Which files are on screen, left to right; each is in `files` too.
    columns: std.ArrayList(*OpenFile) = .empty,

    /// The column with the keyboard, and the one with the pointer while a press
    /// is held. Indices into `columns`.
    focus: usize = 0,
    holding: ?usize = null,

    /// The scratch preview: a file opened from the finder or tree, replaced by
    /// the next one opened rather than kept, so browsing leaves no trail of tabs.
    /// Promoted to null the moment it is edited or its tab double-clicked.
    preview: ?*OpenFile = null,

    /// Opened once at startup. Null only in a window with no finder -- the
    /// healthcheck.
    library: ?fff.Library = null,
    index: ?fff.Index = null,

    finding: ?Finding = null,
    sidebar: Sidebar = .{},

    /// Held so it can be let go when the panel closes: a watch on a tree nobody
    /// is looking at is wakeups for nothing.
    watch_id: ?u64 = null,

    /// One flag for the whole model: presenting blocks, so a redundant frame
    /// costs latency, not just work. True to begin with.
    dirty: bool = true,

    /// False ends the window. Here because a component decides it: only the thing
    /// holding the files knows the last one has closed.
    running: bool = true,

    pub fn init(process: std.process.Init) Model {
        return .{ .allocator = process.gpa, .io = process.io };
    }

    /// The atlas, once there is a window to have made one.
    pub fn attach(self: *Model, atlas: *GlyphAtlas) void {
        self.atlas = atlas;
    }

    /// Opens the library and starts indexing. The walk runs on a thread of the
    /// library's own, so this returns before it finishes and a cmd+P in that
    /// moment searches what has been found so far.
    pub fn locate(self: *Model, environ: std.process.Environ) !void {
        const where = try tools.path(self.allocator, environ, .fff);
        defer self.allocator.free(where);

        // Known to load: startup refused to get this far otherwise.
        self.library = try fff.Library.open(where);
        self.index = try self.library.?.index(".");
    }

    /// One search with nothing typed, for the count the panel shows before a
    /// query narrows it -- which the watcher moves while nobody is looking.
    fn find(self: *Model) !void {
        self.stopFinding();
        self.finding = .{};

        if (self.index) |index| {
            var all = try index.search("");
            defer all.deinit();
            self.finding.?.files = all.files;
        }
        self.changed();
    }

    fn stopFinding(self: *Model) void {
        const finding = &(self.finding orelse return);
        finding.typed.deinit(self.allocator);
        if (finding.found) |*found| found.deinit();
        self.finding = null;
        self.changed();
    }

    fn typeInto(self: *Model, text: []const u8) !void {
        const finding = &(self.finding orelse return);
        try finding.typed.appendSlice(self.allocator, text);
        try self.rank();
    }

    /// One byte at a time, which is wrong the moment the query is not ASCII --
    /// but a query is not a file, and cannot reach `Buffer.stepBack`.
    fn rubOut(self: *Model) !void {
        const finding = &(self.finding orelse return);
        if (finding.typed.items.len == 0) return;
        finding.typed.items.len -= 1;
        try self.rank();
    }

    fn select(self: *Model, by: enum { up, down }) void {
        const finding = &(self.finding orelse return);
        switch (by) {
            .up => if (finding.selected > 0) {
                finding.selected -= 1;
            },
            .down => if (finding.selected + 1 < finding.count()) {
                finding.selected += 1;
            },
        }

        // Keep the selection on screen, without moving further than it has to.
        if (finding.selected < finding.top) finding.top = finding.selected;
        if (finding.selected >= finding.top + visible_matches) {
            finding.top = finding.selected + 1 - visible_matches;
        }
        self.changed();
    }

    /// Nothing typed is nothing offered: the whole repository is not an answer,
    /// and shaping a screenful of it would be thrown away.
    fn rank(self: *Model) !void {
        const finding = &(self.finding orelse return);
        if (finding.found) |*found| found.deinit();
        finding.found = null;
        finding.selected = 0;
        finding.top = 0;
        self.changed();

        const query = finding.typed.items;
        if (query.len == 0) return;

        const index = self.index orelse return;
        const asked = try self.allocator.dupeZ(u8, query);
        defer self.allocator.free(asked);

        const found = try index.search(asked);
        finding.files = found.files;
        finding.found = found;
    }

    /// The model as it now is, and whatever is left for the runtime. The model
    /// comes back rather than being written through a pointer -- value semantics
    /// over the handles it holds -- so nothing can move it but this.
    pub const Answer = struct { Model, ?Effect };

    /// The one place anything here changes. A raw pointer message it hands to
    /// `resolve`, which reads the layout `place` left and answers with a message
    /// saying what was under the pointer; `update` then calls itself with that.
    /// Every branch that falls through asks for a frame at the bottom; those that
    /// answer early or with an effect ask for it themselves.
    pub fn update(start: Model, msg: Message) !Answer {
        var self = start;

        // Handled whatever is in front, before the finder or a column sees it.
        switch (msg) {
            .none => return .{ self, null },
            .quit => {
                self.running = false;
                return .{ self, null };
            },
            // Nothing in the model moved -- the room did, or the palette did --
            // but the window has to be drawn again either way.
            .resized, .themed => {
                self.changed();
                return .{ self, null };
            },
            // A change on disk while nobody is looking is nothing to redraw for:
            // the tree is re-read when it is opened again.
            .disk_changed => {
                if (self.sidebar.open) try self.refreshTree();
                self.changed();
                return .{ self, null };
            },
            .named => |path| {
                const file = self.naming orelse return .{ self, null };
                self.naming = null;

                // The file may have been closed while the dialog was up.
                if (self.indexOf(file) == null) return .{ self, null };

                const owned = try self.allocator.dupe(u8, path);
                if (file.path) |old| self.allocator.free(old);
                file.path = owned;
                self.changed();

                // Written whether changed or not: naming a file is asking to
                // put it there.
                const which = self.columnOf(file) orelse return .{ self, null };
                return .{ self, .{ .save = which } };
            },
            .saved => |which| {
                const file = self.column(which) orelse return .{ self, null };
                file.modified = false;
                self.changed();
                return .{ self, null };
            },
            else => {},
        }

        // The finder takes the keyboard while it is up, and swallows the pointer.
        if (self.finding != null) {
            switch (msg) {
                .cancel, .find => self.stopFinding(),
                .newline => try self.choose(),
                .up => self.select(.up),
                .down => self.select(.down),
                .text => |what| try self.typeInto(what),
                .backspace => try self.rubOut(),
                else => {},
            }
            return .{ self, null };
        }

        switch (msg) {
            // A raw pointer message is turned into what it landed on, then acted
            // on by calling back in with the message that came out.
            .press, .move, .release, .wheel, .look => return self.update(self.resolve(msg)),

            // Typing is an insert into the column with the keyboard; the tab key
            // and return are text that does not arrive as any.
            .text => |t| return self.update(.{ .insert = .{ .column = self.focus, .text = t } }),
            .newline => return self.update(.{ .insert = .{ .column = self.focus, .text = "\n" } }),
            .tab => return self.update(.{ .insert = .{ .column = self.focus, .text = "\t" } }),
            .select_all => {
                const file = self.column(self.focus) orelse return .{ self, null };
                return self.update(.{ .selection = .{ .column = self.focus, .from = 0, .to = file.buffer.byteLen() } });
            },

            .insert => |what| {
                const file = self.column(what.column) orelse return .{ self, null };
                // Typing over a selection replaces it.
                const at = try dropSelection(file);
                _ = try file.insert(at, what.text);
                file.cursor = at + what.text.len;
                file.anchor = file.cursor;
                file.follow_caret = true;
            },
            .backspace => {
                const file = self.column(self.focus) orelse return .{ self, null };
                if (file.hasSelection()) {
                    _ = try dropSelection(file);
                } else {
                    const from = file.buffer.stepBack(file.cursor);
                    if (from == file.cursor) return .{ self, null };
                    _ = try file.delete(from, file.cursor - from);
                    file.cursor = from;
                    file.anchor = from;
                }
                file.follow_caret = true;
            },
            .caret => |where| {
                const file = self.column(where.column) orelse return .{ self, null };
                // A press both chooses the column and takes the pointer, so the
                // drag that may follow stays with it until the release.
                self.focus = where.column;
                self.holding = where.column;
                file.cursor = @min(where.at, file.buffer.byteLen());
                if (!where.extend) file.anchor = file.cursor;
            },
            .selection => |what| {
                const file = self.column(what.column) orelse return .{ self, null };
                self.focus = what.column;
                const end = file.buffer.byteLen();
                file.anchor = @min(what.from, end);
                file.cursor = @min(what.to, end);
                if (what.follow) file.follow_caret = true;
                if (what.warp) file.warp_caret = true;
            },
            .scroll => |where| {
                const file = self.column(where.column) orelse return .{ self, null };
                file.pending = where.pending;
                // Only the fraction moved: nothing to draw until a whole pixel is.
                if (file.scroll == where.to) return .{ self, null };
                file.scroll = where.to;
            },
            .grab => |where| {
                const file = self.column(where.column) orelse return .{ self, null };
                self.focus = where.column;
                self.holding = if (where.at == null) null else where.column;
                file.drag = where.at;
            },
            // Cut is a delete done now and a copy left for the runtime.
            .copy => return .{ self, .{ .copy = self.focus } },
            .paste => return .{ self, .{ .paste = self.focus } },
            .cut => {
                const which = self.focus;
                const file = self.column(which) orelse return .{ self, null };
                if (file.hasSelection()) {
                    _ = try dropSelection(file);
                    file.follow_caret = true;
                }
                self.changed();
                return .{ self, .{ .copy = which } };
            },
            .save => {
                const which = self.focus;
                const file = self.column(which) orelse return .{ self, null };
                if (file.path == null) {
                    self.naming = file;
                    return .{ self, .ask_name };
                }
                if (!file.modified) return .{ self, null };
                return .{ self, .{ .save = which } };
            },

            .show => |nth| try self.showOnly(nth),
            .split => |nth| try self.split(nth),
            .pin => |nth| self.pin(nth),
            .close => try self.shut(),

            // Nothing in a file reads these yet, and the finder is not up.
            .up, .down, .cancel => return .{ self, null },

            .find => try self.find(),

            .toggle_tree => {
                self.sidebar.open = !self.sidebar.open;
                if (self.sidebar.open) {
                    try self.refreshTree();
                    self.changed();
                    return .{ self, if (self.watch_id == null) .watch else null };
                }
                self.sidebar.clearPaths(self.allocator);
                self.changed();
                return .{ self, if (self.watch_id != null) .unwatch else null };
            },
            .toggle_dir => |path| try self.toggleDir(path),
            .open_file => |path| try self.openInFocus(path),
            .scroll_tree => |to| {
                if (self.sidebar.scroll == to) return .{ self, null };
                self.sidebar.scroll = to;
            },

            else => return .{ self, null },
        }

        // An edited preview is a file the reader means to keep. Read once here
        // rather than in every branch that can edit.
        if (self.preview) |file| {
            if (file.modified) self.preview = null;
        }

        self.changed();
        return .{ self, null };
    }

    /// What a raw pointer message means, once the layout `place` left is read:
    /// the tree row, the tab, or the place in a column it fell on. Answered as a
    /// message `update` calls itself with, so the geometry lives here and the
    /// acting lives there.
    fn resolve(self: *const Model, msg: Message) Message {
        switch (msg) {
            .press => |what| {
                if (self.sidebar.open and self.sidebar.rect.contains(what.at))
                    return Tree.resolve(self, msg);

                var nth: usize = 0;
                for (self.files.items) |file| {
                    if (file.path == null) continue;
                    defer nth += 1;
                    if (file.tab_rect.contains(what.at))
                        return if (what.clicks >= 2) .{ .pin = nth } else .{ .show = nth };
                }

                const which = self.columnAt(what.at) orelse return .none;
                return self.columnResolve(which, msg);
            },
            // Only while the pointer is held, so a drag stays with the column it
            // began in and a bare hover reaches no column.
            .move, .release => {
                const which = self.holding orelse return .none;
                return self.columnResolve(which, msg);
            },
            .wheel => |wheel| {
                if (self.sidebar.open and self.sidebar.rect.contains(wheel.at))
                    return Tree.resolve(self, msg);
                const which = self.columnAt(wheel.at) orelse return .none;
                return self.columnResolve(which, msg);
            },
            .look => |at| {
                const which = self.columnAt(at) orelse return .none;
                return self.columnResolve(which, msg);
            },
            else => return msg,
        }
    }

    /// Asks the nth column what a pointer message means, from the rect `place`
    /// left on its file. The view is made on the spot and keeps nothing.
    fn columnResolve(self: *const Model, which: usize, msg: Message) Message {
        const file = self.column(which) orelse return .none;
        const view: TextView = .init(which, file, file.rect);
        return view.resolve(self, msg);
    }

    fn columnAt(self: *const Model, at: [2]f32) ?usize {
        for (self.columns.items, 0..) |file, which| {
            if (file.rect.contains(at)) return which;
        }
        return null;
    }

    /// Writes a file back through a temporary beside it and a rename over the
    /// top, so a write that fails part way leaves the old file rather than half a
    /// new one. Beside it because a rename is only atomic within one filesystem.
    pub fn writeOut(self: *const Model, file: *OpenFile) !void {
        const path = file.path.?;

        // Copies the file when the gap divides it, which a save is about to read
        // every byte of anyway.
        const text = try file.buffer.slice(0, file.buffer.byteLen());

        const restored = if (file.crlf) try withCarriageReturns(self.allocator, text) else null;
        defer if (restored) |owned| self.allocator.free(owned);

        const where = std.fs.path.dirname(path) orelse ".";
        const name = std.fs.path.basename(path);

        var dir = try std.Io.Dir.cwd().openDir(self.io, where, .{});
        defer dir.close(self.io);

        // Hidden and named for what wrote it, so an interrupted save leaves
        // something recognisable.
        const partial = try std.fmt.allocPrint(self.allocator, ".{s}.yaz", .{name});
        defer self.allocator.free(partial);
        errdefer dir.deleteFile(self.io, partial) catch {};

        try dir.writeFile(self.io, .{ .sub_path = partial, .data = restored orelse text });
        try dir.rename(partial, dir, name, self.io);
    }

    /// Public because performing an effect needs it, and that happens outside.
    pub fn column(self: *const Model, which: usize) ?*OpenFile {
        if (which >= self.columns.items.len) return null;
        return self.columns.items[which];
    }

    /// Nothing selected leaves the clipboard alone, so cutting nothing does not
    /// throw away what somebody put there. SDL's clipboard is a C string, so a
    /// file holding a zero byte copies as far as the first one.
    pub fn copyOut(self: *Model, which: usize) !void {
        const file = self.column(which) orelse return;
        const chosen = file.selected();
        if (chosen.empty()) return;

        // Terminated for SDL, and good past the buffer's next call, which its own
        // slice is not.
        const text = try file.buffer.slice(chosen.from, chosen.to);
        const owned = try self.allocator.dupeZ(u8, text);
        defer self.allocator.free(owned);

        if (!c.SDL_SetClipboardText(owned.ptr)) {
            std.log.err("SDL_SetClipboardText: {s}", .{sdl.lastError()});
        }
    }

    /// The clipboard with its line endings mended, or none when empty. Caller
    /// owns the result; typing it in is an `.insert` like any keystroke.
    pub fn clipboard(self: *const Model) !?[]u8 {
        const given = c.SDL_GetClipboardText();
        if (given == null) return null;
        defer c.SDL_free(given);

        const text = std.mem.span(given);
        if (text.len == 0) return null;

        return try unixEndings(self.allocator, text) orelse
            try self.allocator.dupe(u8, text);
    }

    /// Takes out whatever is selected and answers where the caret ends up.
    /// Nothing selected removes nothing, so anything that edits can call it first.
    fn dropSelection(file: *OpenFile) !usize {
        const chosen = file.selected();
        if (chosen.to == chosen.from) return file.cursor;

        _ = try file.delete(chosen.from, chosen.to - chosen.from);
        file.cursor = chosen.from;
        file.anchor = chosen.from;
        return chosen.from;
    }

    fn changed(self: *Model) void {
        self.dirty = true;
    }

    /// The nth named file, which is the nth tab: an unnamed file has no tab.
    fn tab(self: *const Model, which: usize) ?*OpenFile {
        var counted: usize = 0;
        for (self.files.items) |file| {
            if (file.path == null) continue;
            if (counted == which) return file;
            counted += 1;
        }
        return null;
    }

    /// Shows the nth file and nothing else; every other column goes off screen.
    fn showOnly(self: *Model, nth: usize) !void {
        const wanted = self.tab(nth) orelse return;
        self.columns.clearRetainingCapacity();
        try self.columns.append(self.allocator, wanted);
        self.focus = 0;
    }

    /// Puts the nth file beside what is shown, or takes it away when it already
    /// is. Taking it away is not closing it; the last column cannot go.
    fn split(self: *Model, nth: usize) !void {
        const wanted = self.tab(nth) orelse return;

        if (self.columnOf(wanted)) |which| {
            if (self.columns.items.len == 1) return;
            _ = self.columns.orderedRemove(which);
            if (self.focus >= self.columns.items.len) self.focus = self.columns.items.len - 1;
            return;
        }

        // Columns follow the bar's order, so one put back lands where it was
        // rather than on the end.
        const listed = self.indexOf(wanted) orelse return;
        var at: usize = 0;
        for (self.columns.items) |shown| {
            const seen = self.indexOf(shown) orelse continue;
            if (seen < listed) at += 1;
        }
        try self.columns.insert(self.allocator, at, wanted);
        self.focus = at;
    }

    /// Takes the focused file out of the window and memory. The window does not
    /// close on its last file -- it falls back to a blank; closing that blank in
    /// turn is the way out.
    fn shut(self: *Model) !void {
        const closing = self.showing() orelse return;

        if (self.files.items.len == 1 and closing.path == null) {
            self.running = false;
            return;
        }

        // The last column stays; something has to be there to type into.
        if (self.columns.items.len > 1) {
            _ = self.columns.orderedRemove(self.focus);
            if (self.focus >= self.columns.items.len) self.focus = self.columns.items.len - 1;
        } else {
            var next: ?*OpenFile = null;
            for (self.files.items) |file| {
                if (file != closing and file.path != null) {
                    next = file;
                    break;
                }
            }
            self.columns.items[0] = next orelse try self.blank();
        }

        self.close(closing);
    }

    /// Opens what the finder has selected and puts the finder away.
    fn choose(self: *Model) !void {
        const picked = blk: {
            const finding = &(self.finding orelse return);
            break :blk finding.chosen() orelse return;
        };

        // Copied, because opening it frees the listing the path points into.
        const path = try self.allocator.dupe(u8, picked);
        defer self.allocator.free(path);
        self.stopFinding();

        try self.openInFocus(path);
    }

    /// Opens `path` in the focused column, or moves to it if already on screen. A
    /// freshly opened file is a scratch preview; a reopened one is a kept tab, so
    /// opening one file after another leaves one tab, not a row of them.
    fn openInFocus(self: *Model, path: []const u8) !void {
        // Asked before opening: reopening a tab must not turn it into a preview.
        const fresh = self.opened(path) == null;
        const wanted = try self.open(path);

        if (self.columnOf(wanted)) |which| {
            self.focus = which;
            return;
        }

        const leaving = self.column(self.focus);

        if (self.focus < self.columns.items.len) {
            self.columns.items[self.focus] = wanted;
        } else {
            try self.columns.append(self.allocator, wanted);
            self.focus = self.columns.items.len - 1;
        }

        // The preview the column just left is done; the new file takes its tab.
        if (leaving) |gone| {
            if (gone == self.preview) self.close(gone);
        }

        if (fresh) self.preview = wanted;
    }

    /// Promotes the nth tab out of being the scratch preview.
    fn pin(self: *Model, which: usize) void {
        const file = self.tab(which) orelse return;
        if (self.preview == file) self.preview = null;
    }

    /// Re-reads the tree into `sidebar.paths`, sorted. The paths are copied out,
    /// so the tree does not hold the library's answer while it is on screen.
    fn refreshTree(self: *Model) !void {
        const index = self.index orelse return;

        var listed = try index.enumerate();
        defer listed.deinit();

        self.sidebar.clearPaths(self.allocator);
        try self.sidebar.paths.ensureTotalCapacity(self.allocator, listed.count);

        var nth: u32 = 0;
        while (nth < listed.count) : (nth += 1) {
            const path = listed.path(nth) orelse continue;
            const owned = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned);
            try self.sidebar.paths.append(self.allocator, owned);
        }

        std.mem.sort([]const u8, self.sidebar.paths.items, {}, lessPath);
        self.sidebar.revision +%= 1;
    }

    /// The key is copied in, since the path it came from is a row the next
    /// rebuild throws away.
    fn toggleDir(self: *Model, path: []const u8) !void {
        if (self.sidebar.expanded.fetchRemove(path)) |gone| {
            self.allocator.free(gone.key);
        } else {
            const key = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(key);
            try self.sidebar.expanded.put(self.allocator, key, {});
        }
        self.sidebar.revision +%= 1;
    }

    /// A watch that will not start is a tree that does not update on its own, not
    /// a window that cannot go up, so its failure is logged rather than returned.
    /// Performed outside the model because it registers a callback that pushes an
    /// SDL event.
    pub fn watchTree(self: *Model) void {
        const index = self.index orelse return;
        if (self.watch_id != null) return;
        self.watch_id = index.watch(onDiskChange, null) catch |err| {
            std.log.err("sidebar watch: {s}", .{@errorName(err)});
            return;
        };
    }

    /// A no-op when there is no watch, so it is safe to call on the way out.
    pub fn unwatchTree(self: *Model) void {
        const index = self.index orelse return;
        const id = self.watch_id orelse return;
        index.unwatch(id);
        self.watch_id = null;
    }

    /// What the focused column is showing, or none before there is a column.
    pub fn showing(self: *const Model) ?*OpenFile {
        if (self.focus >= self.columns.items.len) return null;
        return self.columns.items[self.focus];
    }

    pub fn onScreen(self: *const Model, file: *const OpenFile) bool {
        for (self.columns.items) |shown| {
            if (shown == file) return true;
        }
        return false;
    }

    fn columnOf(self: *const Model, file: *const OpenFile) ?usize {
        for (self.columns.items, 0..) |shown, which| {
            if (shown == file) return which;
        }
        return null;
    }

    pub fn deinit(self: *Model) void {
        self.stopFinding();
        self.unwatchTree();
        self.tab_bullet.deinit(self.allocator);
        self.sidebar.deinit(self.allocator);
        if (self.index) |*indexed| indexed.close();
        if (self.library) |*loaded| loaded.close();
        self.columns.deinit(self.allocator);
        for (self.files.items) |file| {
            file.deinit();
            self.allocator.destroy(file);
        }
        self.files.deinit(self.allocator);
    }

    /// The file called `path`, opened if it is not already. Asking twice gives
    /// the same file back, so two columns cannot show copies that drift apart.
    pub fn open(self: *Model, path: []const u8) !*OpenFile {
        if (self.opened(path)) |already| return already;

        const was = try self.read(path);
        defer self.allocator.free(was.text);
        return self.hold(was.text, path, was.crlf);
    }

    /// An empty, nameless file, which is what a window with nothing to show has.
    pub fn blank(self: *Model) !*OpenFile {
        return self.hold("", null, false);
    }

    fn opened(self: *Model, path: []const u8) ?*OpenFile {
        for (self.files.items) |file| {
            const named = file.path orelse continue;
            if (std.mem.eql(u8, named, path)) return file;
        }
        return null;
    }

    fn indexOf(self: *Model, file: *const OpenFile) ?usize {
        for (self.files.items, 0..) |listed, which| {
            if (listed == file) return which;
        }
        return null;
    }

    /// Out of the window and out of memory.
    fn close(self: *Model, file: *OpenFile) void {
        // The preview is the one thing besides a column that might point at it.
        if (self.preview == file) self.preview = null;
        const which = self.indexOf(file) orelse return;
        _ = self.files.orderedRemove(which);
        file.deinit();
        self.allocator.destroy(file);
    }

    fn hold(self: *Model, text: []const u8, path: ?[]const u8, crlf: bool) !*OpenFile {
        const file = try self.allocator.create(OpenFile);
        errdefer self.allocator.destroy(file);

        file.* = try OpenFile.init(self.allocator, text, path);
        errdefer file.deinit();

        // Remembered so saving can put the line endings back as they came.
        file.crlf = crlf;

        try self.files.append(self.allocator, file);
        return file;
    }

    fn read(self: *Model, named: []const u8) !Read {
        const allocator = self.allocator;
        const path = try allocator.dupeZ(u8, named);
        defer allocator.free(path);

        const contents = std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(file_limit)) catch |err| switch (err) {
            // A file that is not there yet is an empty one that will be, which
            // is what makes `yaz new.txt` and a save all it takes to write one.
            error.FileNotFound => return .{ .text = try allocator.alloc(u8, 0), .crlf = false },
            error.StreamTooLong => {
                std.log.err(
                    "{s} is larger than the {d}MB yaz will open: the layout cache holds an entry for every line of it, on screen or not",
                    .{ path, file_limit >> 20 },
                );
                return error.FileTooLarge;
            },
            else => |other| {
                std.log.err("{s}: {s}", .{ path, @errorName(other) });
                return other;
            },
        };
        errdefer allocator.free(contents);

        if (firstInvalidUtf8(contents)) |offset| {
            std.log.err("{s} is not UTF-8: the byte at offset {d} does not begin or continue a character", .{ path, offset });
            return error.InvalidUtf8;
        }

        return stripCarriageReturns(allocator, contents);
    }
};

/// Bytewise, which puts a folder's files in the order the fold expects.
fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Called on the library's watcher thread, so it touches nothing but SDL and the
/// batch. Which paths changed is not read: the tree re-reads the whole index.
fn onDiskChange(_: u64, batch: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    sdl.pushTreeChanged();
    if (batch) |owned| fff.freeWatchEvents(owned);
}

/// The offset of the first invalid byte, or none. Worth refusing over: HarfBuzz
/// would only draw a replacement character, but `stepBack` walks continuation
/// bytes, so backspace over stray ones would delete however many are adjacent.
fn firstInvalidUtf8(text: []const u8) ?usize {
    // Not `utf8ValidateSlice` with this only on failure: two deciders of what
    // UTF-8 is would, the day they disagreed, leave nothing to point at.
    var at: usize = 0;
    while (at < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[at]) catch return at;
        // Truncated: report where the sequence began, not where the bytes ran out.
        if (at + length > text.len) return at;
        _ = std.unicode.utf8Decode(text[at..][0..length]) catch return at;
        at += length;
    }
    return null;
}

test "firstInvalidUtf8 accepts what the sample file is made of" {
    try std.testing.expectEqual(@as(?usize, null), firstInvalidUtf8(""));
    try std.testing.expectEqual(@as(?usize, null), firstInvalidUtf8("plain ascii\n"));
    // Precomposed, then a combining mark, then an em dash and CJK.
    try std.testing.expectEqual(@as(?usize, null), firstInvalidUtf8("caf\u{e9} cafe\u{301} \u{2014} \u{6f22}"));
}

test "firstInvalidUtf8 points at a stray continuation byte" {
    // 0x80 continues a character that never began.
    try std.testing.expectEqual(@as(?usize, 3), firstInvalidUtf8("abc\x80def"));
}

test "firstInvalidUtf8 points at a truncated sequence" {
    // 0xE2 opens a three-byte sequence and the file ends inside it. The offset
    // is where the sequence began, not where the bytes ran out.
    try std.testing.expectEqual(@as(?usize, 2), firstInvalidUtf8("ab\xe2\x82"));
}

test "firstInvalidUtf8 rejects an overlong encoding" {
    // 0xC0 0x80 is a two-byte spelling of NUL, which is not valid UTF-8 even
    // though both bytes are individually plausible.
    try std.testing.expectEqual(@as(?usize, 0), firstInvalidUtf8("\xc0\x80"));
}

test "firstInvalidUtf8 rejects a surrogate half" {
    // ED A0 80 is U+D800, encodable as bytes but not a scalar value.
    try std.testing.expectEqual(@as(?usize, 0), firstInvalidUtf8("\xed\xa0\x80"));
}

/// Turns CRLF into LF, freeing what it is given only if it has to replace it. A
/// carriage return is not a line break here, so left in it would shape as .notdef
/// at the end of every line.
fn stripCarriageReturns(allocator: std.mem.Allocator, text: []u8) !Read {
    var found: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte == '\r' and i + 1 < text.len and text[i + 1] == '\n') found += 1;
    }
    if (found == 0) return .{ .text = text, .crlf = false };

    const stripped = try allocator.alloc(u8, text.len - found);
    var out: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
        stripped[out] = byte;
        out += 1;
    }
    std.debug.assert(out == stripped.len);

    allocator.free(text);
    return .{ .text = stripped, .crlf = true };
}

/// The text, and whether its lines ended with a carriage return before it was
/// stripped -- the only chance to know, since the returns are gone by then.
const Read = struct {
    text: []u8,
    crlf: bool,
};

/// The text with a carriage return before every newline: how a file that came in
/// with them goes back out.
fn withCarriageReturns(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const breaks = std.mem.count(u8, text, "\n");
    const out = try allocator.alloc(u8, text.len + breaks);

    var at: usize = 0;
    for (text) |byte| {
        if (byte == '\n') {
            out[at] = '\r';
            at += 1;
        }
        out[at] = byte;
        at += 1;
    }
    std.debug.assert(at == out.len);

    return out;
}

test "a file that came in with carriage returns goes back out with them" {
    const out = try withCarriageReturns(std.testing.allocator, "one\ntwo\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("one\r\ntwo\r\n", out);
}

test "a file with no line endings at all is unchanged by either direction" {
    const out = try withCarriageReturns(std.testing.allocator, "one line");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("one line", out);
}

test "stripCarriageReturns leaves a file that has none alone" {
    const allocator = std.testing.allocator;
    const text = try allocator.dupe(u8, "one\ntwo\n");
    const kept = try stripCarriageReturns(allocator, text);
    defer allocator.free(kept.text);
    // The same allocation, not a copy of it.
    try std.testing.expectEqual(text.ptr, kept.text.ptr);
    // And nothing for a save to put back.
    try std.testing.expect(!kept.crlf);
}

test "stripCarriageReturns turns CRLF into LF" {
    const allocator = std.testing.allocator;
    const text = try allocator.dupe(u8, "one\r\ntwo\r\n");
    const stripped = try stripCarriageReturns(allocator, text);
    defer allocator.free(stripped.text);
    try std.testing.expectEqualStrings("one\ntwo\n", stripped.text);
    // Remembered, so that saving writes the file back as it was found.
    try std.testing.expect(stripped.crlf);
}

test "stripCarriageReturns keeps a carriage return that is not a line ending" {
    const allocator = std.testing.allocator;
    // A lone CR is not CRLF and is left where it is; only the pair is a line
    // ending, and a file using bare CR is not a thing this reads.
    const text = try allocator.dupe(u8, "one\rtwo\r\n");
    const stripped = try stripCarriageReturns(allocator, text);
    defer allocator.free(stripped.text);
    try std.testing.expectEqualStrings("one\rtwo\n", stripped.text);
}

test "stripCarriageReturns handles a trailing carriage return" {
    const allocator = std.testing.allocator;
    // Last byte, so there is no next one to look at; the bounds check is the
    // whole of what this is here to catch.
    const text = try allocator.dupe(u8, "one\n\r");
    const stripped = try stripCarriageReturns(allocator, text);
    defer allocator.free(stripped.text);
    try std.testing.expectEqualStrings("one\n\r", stripped.text);
}

/// Clipboard text with CRLF (Windows) or bare CR (old Mac) turned into the LF
/// the line index counts, or null when there is nothing to mend. Only `\n`
/// starts a line here, so a stray `\r` would draw as a glyph at every line end.
fn unixEndings(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    if (std.mem.indexOfScalar(u8, text, '\r') == null) return null;

    var mended: std.ArrayList(u8) = .empty;
    errdefer mended.deinit(allocator);
    // No more than what came in: every ending either shrinks or stays.
    try mended.ensureTotalCapacity(allocator, text.len);

    var at: usize = 0;
    while (at < text.len) : (at += 1) {
        if (text[at] != '\r') {
            mended.appendAssumeCapacity(text[at]);
            continue;
        }
        // A CR is one line ending whether an LF follows it or not.
        mended.appendAssumeCapacity('\n');
        if (at + 1 < text.len and text[at + 1] == '\n') at += 1;
    }

    return try mended.toOwnedSlice(allocator);
}

test "clipboard text that already ends its lines the right way is left alone" {
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try unixEndings(std.testing.allocator, "one\ntwo\n"),
    );
}

test "a CRLF from another window becomes the ending the file counts" {
    const mended = (try unixEndings(std.testing.allocator, "one\r\ntwo\r\n")).?;
    defer std.testing.allocator.free(mended);
    try std.testing.expectEqualStrings("one\ntwo\n", mended);
}

test "a CR on its own is a line ending too" {
    const mended = (try unixEndings(std.testing.allocator, "one\rtwo\r\nthree")).?;
    defer std.testing.allocator.free(mended);
    try std.testing.expectEqualStrings("one\ntwo\nthree", mended);
}

fn moved(model: *Model, change: Message) !?Effect {
    const next, const effect = model.update(change) catch |err| return err;
    model.* = next;
    return effect;
}

/// As much of the runtime's half as a test can do: writing a file needs no
/// window, unlike the clipboard and the dialog.
fn performed(model: *Model, effect: Effect) !void {
    switch (effect) {
        .save => |which| {
            const file = model.column(which).?;
            try model.writeOut(file);
            _ = try moved(model, .{ .saved = which });
        },
        else => unreachable,
    }
}

fn moveAndPerform(model: *Model, change: Message) !void {
    if (try moved(model, change)) |effect| try performed(model, effect);
}

/// A model with one file in one column. The io is never reached.
fn oneOpenFile(allocator: std.mem.Allocator, text: []const u8) !Model {
    var model: Model = .{ .allocator = allocator, .io = undefined };
    errdefer model.deinit();

    const file = try allocator.create(OpenFile);
    file.* = OpenFile.init(allocator, text, null) catch |err| {
        allocator.destroy(file);
        return err;
    };

    try model.files.append(allocator, file);
    try model.columns.append(allocator, file);
    return model;
}

fn whatIsIn(model: *Model) ![]const u8 {
    const file = model.columns.items[0];
    return file.buffer.slice(0, file.buffer.byteLen());
}

test "typing over a selection replaces it" {
    var model = try oneOpenFile(std.testing.allocator, "one two three");
    defer model.deinit();

    _ = try moved(&model, .{ .selection = .{ .column = 0, .from = 4, .to = 7 } });
    _ = try moved(&model, .{ .insert = .{ .column = 0, .text = "six" } });

    try std.testing.expectEqualStrings("one six three", try whatIsIn(&model));

    // The caret lands after what was typed, with nothing selected.
    const file = model.columns.items[0];
    try std.testing.expectEqual(@as(usize, 7), file.cursor);
    try std.testing.expect(!file.hasSelection());
}

test "backspace over a selection takes the selection and no more" {
    var model = try oneOpenFile(std.testing.allocator, "one two three");
    defer model.deinit();

    _ = try moved(&model, .{ .selection = .{ .column = 0, .from = 4, .to = 7 } });
    _ = try moved(&model, .backspace);

    // The space before `two` survives: a selection, not a selection and a char.
    try std.testing.expectEqualStrings("one  three", try whatIsIn(&model));
    try std.testing.expectEqual(@as(usize, 4), model.columns.items[0].cursor);
}

test "backspace with no selection still takes the character before the caret" {
    var model = try oneOpenFile(std.testing.allocator, "one two");
    defer model.deinit();

    _ = try moved(&model, .{ .caret = .{ .column = 0, .at = 3 } });
    _ = try moved(&model, .backspace);

    try std.testing.expectEqualStrings("on two", try whatIsIn(&model));
}

test "a press collapses the selection and a shifted one extends it" {
    var model = try oneOpenFile(std.testing.allocator, "one two three");
    defer model.deinit();
    const file = model.columns.items[0];

    _ = try moved(&model, .{ .caret = .{ .column = 0, .at = 4 } });
    try std.testing.expect(!file.hasSelection());

    // Shifted: the far end stays at 4 and only this end moves.
    _ = try moved(&model, .{ .caret = .{ .column = 0, .at = 7, .extend = true } });
    try std.testing.expectEqual(Span{ .from = 4, .to = 7 }, file.selected());

    // Unshifted: whatever was selected is let go of.
    _ = try moved(&model, .{ .caret = .{ .column = 0, .at = 9 } });
    try std.testing.expect(!file.hasSelection());
}

test "a selection past the end of the file is clamped to it" {
    var model = try oneOpenFile(std.testing.allocator, "one");
    defer model.deinit();

    _ = try moved(&model, .{ .selection = .{ .column = 0, .from = 0, .to = 99 } });
    try std.testing.expectEqual(Span{ .from = 0, .to = 3 }, model.columns.items[0].selected());
}

/// A model whose one file is on disk at `path`, with a real io to reach it by.
fn oneSavedFile(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !Model {
    var model = try oneOpenFile(allocator, text);
    errdefer model.deinit();

    model.io = std.testing.io;
    model.columns.items[0].path = try allocator.dupe(u8, path);
    return model;
}

/// A tmp path relative to the working directory, which is what `writeOut` opens.
fn under(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "saving writes the file back where it came from and clears the mark" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try under(allocator, &tmp, "kept.txt");
    defer allocator.free(path);

    var model = try oneSavedFile(allocator, path, "");
    defer model.deinit();
    const file = model.columns.items[0];

    _ = try moved(&model, .{ .insert = .{ .column = 0, .text = "kept\n" } });
    try std.testing.expect(file.modified);

    try moveAndPerform(&model, .save);
    try std.testing.expect(!file.modified);

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 16));
    defer allocator.free(written);
    try std.testing.expectEqualStrings("kept\n", written);
}

test "a file that came in with carriage returns is written back with them" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try under(allocator, &tmp, "windows.txt");
    defer allocator.free(path);

    var model = try oneSavedFile(allocator, path, "one\ntwo\n");
    defer model.deinit();

    const file = model.columns.items[0];
    file.crlf = true;

    _ = try moved(&model, .{ .insert = .{ .column = 0, .text = "x" } });
    try moveAndPerform(&model, .save);

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 16));
    defer allocator.free(written);

    // What is on screen has one ending; what is on disk has the other.
    try std.testing.expectEqualStrings("xone\r\ntwo\r\n", written);
}

test "saving a file nothing has changed writes nothing at all" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try under(allocator, &tmp, "untouched.txt");
    defer allocator.free(path);

    var model = try oneSavedFile(allocator, path, "as it was");
    defer model.deinit();

    try moveAndPerform(&model, .save);

    // Not even created: a save with nothing to do touches nothing.
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 16)),
    );
}

test "a save leaves nothing of its own behind" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try under(allocator, &tmp, "tidy.txt");
    defer allocator.free(path);

    var model = try oneSavedFile(allocator, path, "");
    defer model.deinit();

    _ = try moved(&model, .{ .insert = .{ .column = 0, .text = "written" } });
    try moveAndPerform(&model, .save);

    // The temporary the write went through is renamed, not left beside it.
    var walker = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer walker.close(std.testing.io);

    var seen: usize = 0;
    var listing = walker.iterate();
    while (try listing.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("tidy.txt", entry.name);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "a file given a name is written under it and keeps it" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try under(allocator, &tmp, "named.txt");
    defer allocator.free(path);

    var model = try oneOpenFile(allocator, "");
    defer model.deinit();
    model.io = std.testing.io;

    const file = model.columns.items[0];
    try std.testing.expect(file.path == null);

    _ = try moved(&model, .{ .insert = .{ .column = 0, .text = "somewhere" } });

    // What the dialog's answer arriving looks like from here.
    model.naming = file;
    try moveAndPerform(&model, .{ .named = path });

    try std.testing.expectEqualStrings(path, file.path.?);
    try std.testing.expect(!file.modified);
    try std.testing.expect(model.naming == null);

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 16));
    defer allocator.free(written);
    try std.testing.expectEqualStrings("somewhere", written);
}

test "a name that comes back for a file that has gone is dropped" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try under(allocator, &tmp, "gone.txt");
    defer allocator.free(path);

    var model = try oneOpenFile(allocator, "still here");
    defer model.deinit();
    model.io = std.testing.io;

    // A file the model does not hold, standing in for one cmd+W closed and
    // freed while the dialog was up.
    var closed = try OpenFile.init(allocator, "", null);
    defer closed.deinit();

    model.naming = &closed;
    try moveAndPerform(&model, .{ .named = path });

    // Nothing written, and the file the window does have is untouched.
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 16)),
    );
    try std.testing.expect(model.columns.items[0].path == null);
}

test "asking for a name a second time replaces the first" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try under(allocator, &tmp, "first.txt");
    defer allocator.free(first);
    const second = try under(allocator, &tmp, "second.txt");
    defer allocator.free(second);

    var model = try oneOpenFile(allocator, "text");
    defer model.deinit();
    model.io = std.testing.io;

    const file = model.columns.items[0];

    model.naming = file;
    try moveAndPerform(&model, .{ .named = first });

    model.naming = file;
    try moveAndPerform(&model, .{ .named = second });

    // The testing allocator checks the old path was freed, not leaked.
    try std.testing.expectEqualStrings(second, file.path.?);
}

test "cutting takes the selection and leaves the caret where it began" {
    const allocator = std.testing.allocator;
    var model = try oneOpenFile(allocator, "one two three");
    defer model.deinit();

    _ = try moved(&model, .{ .selection = .{ .column = 0, .from = 4, .to = 8 } });
    // Cut is the one path that still takes a selection out on its own.
    _ = try moved(&model, .cut);

    try std.testing.expectEqualStrings("one three", try whatIsIn(&model));

    const file = model.columns.items[0];
    try std.testing.expectEqual(@as(usize, 4), file.cursor);
    try std.testing.expect(!file.hasSelection());
}

test "update answers with the model and what is left to be done" {
    const allocator = std.testing.allocator;
    var model = try oneOpenFile(allocator, "one two");
    defer model.deinit();

    // A change the model can make itself leaves nothing for anyone else.
    {
        const next, const effect = try model.update(.{ .caret = .{ .column = 0, .at = 3 } });
        model = next;
        try std.testing.expect(effect == null);
        try std.testing.expectEqual(@as(usize, 3), model.columns.items[0].cursor);
    }

    // One it cannot comes back as an effect, and moves nothing.
    {
        const next, const effect = try model.update(.copy);
        model = next;
        try std.testing.expectEqual(@as(usize, 0), effect.?.copy);
        try std.testing.expectEqualStrings("one two", try whatIsIn(&model));
    }
}

test "a save with no name asks for one and remembers which file is waiting" {
    const allocator = std.testing.allocator;
    var model = try oneOpenFile(allocator, "");
    defer model.deinit();

    const asked = (try moved(&model, .save)).?;
    try std.testing.expectEqual(Effect.ask_name, asked);

    // Remembered here because the answer arrives long after this returned.
    try std.testing.expectEqual(model.columns.items[0], model.naming.?);
}

test "a save with nothing to write asks for nothing" {
    const allocator = std.testing.allocator;
    var model = try oneSavedFile(allocator, "unread.txt", "as it was");
    defer model.deinit();

    try std.testing.expect(try moved(&model, .save) == null);
}

test "being told a file was written clears the mark on its tab" {
    const allocator = std.testing.allocator;
    var model = try oneOpenFile(allocator, "");
    defer model.deinit();

    _ = try moved(&model, .{ .insert = .{ .column = 0, .text = "typed" } });
    try std.testing.expect(model.columns.items[0].modified);

    _ = try moved(&model, .{ .saved = 0 });
    try std.testing.expect(!model.columns.items[0].modified);
}


test "closing the last file leaves a blank rather than closing the window" {
    const allocator = std.testing.allocator;
    var model = try oneOpenFile(allocator, "text");
    defer model.deinit();

    // A named file, so it is a file rather than the blank a fresh window has.
    model.columns.items[0].path = try allocator.dupe(u8, "a.txt");

    _ = try moved(&model, .close);

    try std.testing.expect(model.running);
    try std.testing.expectEqual(@as(usize, 1), model.files.items.len);
    try std.testing.expectEqual(@as(usize, 1), model.columns.items.len);
    try std.testing.expect(model.showing().?.path == null);
}

test "closing the blank a last file left behind closes the window" {
    const allocator = std.testing.allocator;
    var model = try oneOpenFile(allocator, "text");
    defer model.deinit();

    model.columns.items[0].path = try allocator.dupe(u8, "a.txt");

    // The last file goes to a blank, and the window stays up.
    _ = try moved(&model, .close);
    try std.testing.expect(model.running);

    // Closing that blank in turn is the way out.
    _ = try moved(&model, .close);
    try std.testing.expect(!model.running);
}

test "closing a window that never had a file named closes it" {
    const allocator = std.testing.allocator;
    var model = try oneOpenFile(allocator, "");
    defer model.deinit();

    _ = try moved(&model, .close);
    try std.testing.expect(!model.running);
}

/// A window on a blank, with an io to open files by. The names below do not
/// exist, so opening one is an empty file with that path.
fn browsing(allocator: std.mem.Allocator) !Model {
    var model = try oneOpenFile(allocator, "");
    errdefer model.deinit();
    model.io = std.testing.io;
    return model;
}

fn isOpen(model: *const Model, path: []const u8) bool {
    for (model.files.items) |file| {
        const named = file.path orelse continue;
        if (std.mem.eql(u8, named, path)) return true;
    }
    return false;
}

test "opening one file after another replaces the scratch preview" {
    const allocator = std.testing.allocator;
    var model = try browsing(allocator);
    defer model.deinit();

    _ = try moved(&model, .{ .open_file = "scratch-a.zzz" });
    try std.testing.expect(model.preview == model.showing().?);
    try std.testing.expect(isOpen(&model, "scratch-a.zzz"));

    _ = try moved(&model, .{ .open_file = "scratch-b.zzz" });
    // The second takes the first's place, rather than leaving it on a tab.
    try std.testing.expectEqualStrings("scratch-b.zzz", model.showing().?.path.?);
    try std.testing.expect(!isOpen(&model, "scratch-a.zzz"));
    try std.testing.expect(model.preview == model.showing().?);
}

test "editing a previewed file keeps it, so the next opens beside it" {
    const allocator = std.testing.allocator;
    var model = try browsing(allocator);
    defer model.deinit();

    _ = try moved(&model, .{ .open_file = "scratch-a.zzz" });
    try std.testing.expect(model.preview != null);

    // A keystroke is what promotes it: the mark on its tab is the same fact.
    _ = try moved(&model, .{ .insert = .{ .column = 0, .text = "x" } });
    try std.testing.expect(model.preview == null);

    _ = try moved(&model, .{ .open_file = "scratch-b.zzz" });
    // The edited one was kept, so both are open.
    try std.testing.expect(isOpen(&model, "scratch-a.zzz"));
    try std.testing.expect(isOpen(&model, "scratch-b.zzz"));
}

test "double-clicking a tab keeps it out of being replaced" {
    const allocator = std.testing.allocator;
    var model = try browsing(allocator);
    defer model.deinit();

    _ = try moved(&model, .{ .open_file = "scratch-a.zzz" });
    try std.testing.expect(model.preview != null);

    // The blank has no tab, so the opened file is the only one on the bar.
    _ = try moved(&model, .{ .pin = 0 });
    try std.testing.expect(model.preview == null);

    _ = try moved(&model, .{ .open_file = "scratch-b.zzz" });
    try std.testing.expect(isOpen(&model, "scratch-a.zzz"));
    try std.testing.expect(isOpen(&model, "scratch-b.zzz"));
}

test "reopening a kept file does not turn it back into a preview" {
    const allocator = std.testing.allocator;
    var model = try browsing(allocator);
    defer model.deinit();

    // Keep a.zzz, then browse to a preview b.zzz beside it.
    _ = try moved(&model, .{ .open_file = "scratch-a.zzz" });
    _ = try moved(&model, .{ .pin = 0 });
    _ = try moved(&model, .{ .open_file = "scratch-b.zzz" });
    try std.testing.expect(model.preview == model.showing().?);

    // Coming back to the kept file focuses it and leaves nothing a preview, so
    // the scratch b.zzz it displaced is gone rather than kept.
    _ = try moved(&model, .{ .open_file = "scratch-a.zzz" });
    try std.testing.expectEqualStrings("scratch-a.zzz", model.showing().?.path.?);
    try std.testing.expect(model.preview == null);
    try std.testing.expect(!isOpen(&model, "scratch-b.zzz"));
}
