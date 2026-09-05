//! The state the window is showing, and the only thing that outlives a frame.
//!
//! Handed to `place`, `update` and `draw` as the first argument rather than
//! stored: a component that kept a copy of the allocator would have a second
//! one to keep in step with this, which is the thing this is here to stop, and
//! the atlas was threaded through every one of those calls by hand.
//!
//! What a component keeps is where it drew things. What files are open, which
//! are on screen, where each caret is and whether the window is still up are
//! all here, so drawing is a matter of reading this rather than of asking
//! around.

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

/// The largest file yaz will open. What still costs per line of the file
/// rather than per line on screen is the layout cache, which holds a 64-byte
/// entry for each of them, and the line index behind it.
const file_limit = 1 << 20;

/// How many matches the finder shows at once. Here rather than with the panel
/// that draws them because moving the selection has to keep it on screen, and
/// that is a change to the state rather than to the drawing of it.
pub const visible_matches = 12;

/// The file finder, while it is open. Null when it is not, which is the whole
/// of what "the panel is open" means.
///
/// It holds no listing of its own. The index is the library's and lives for as
/// long as the window does; what is here is the query, and the answer to it.
pub const Finding = struct {
    /// What has been typed into it.
    typed: std.ArrayList(u8) = .empty,

    /// What the query matched. Owned: the paths point into it, so it is freed
    /// when the query changes and when the panel closes.
    found: ?fff.Matches = null,

    /// How many files the index holds. Read once when the panel opens, and
    /// again from every search, since the watcher moves it while the panel is
    /// up.
    files: u32 = 0,

    /// Which match return would open, and which is the first on screen. The
    /// second follows the first rather than leading it.
    selected: usize = 0,
    top: usize = 0,

    pub fn count(self: *const Finding) usize {
        const found = self.found orelse return 0;
        return found.count;
    }

    /// Which set of matches these are, for anything caching what it drew of
    /// them. A new search is a new one; nothing else is.
    pub fn token(self: *const Finding) ?*anyopaque {
        const found = self.found orelse return null;
        return found.handle;
    }

    /// The nth match, or none past the end.
    pub fn path(self: *const Finding, nth: usize) ?[]const u8 {
        const found = self.found orelse return null;
        return found.path(@intCast(nth));
    }

    /// What return would open.
    fn chosen(self: *const Finding) ?[]const u8 {
        return self.path(self.selected);
    }
};

/// The sidebar tree, whether it is open or not.
///
/// It holds a listing of its own rather than reading the finder's: the finder
/// answers a query, best first and cut to a screenful, which is the wrong shape
/// for a tree. This is the whole of what the index holds, sorted by path, and
/// the folders the reader has opened over it.
/// One line of the folded tree: a path (borrowed from `Sidebar.paths`), its
/// last segment, how deep it sits, and whether it is a folder. On the sidebar so
/// `update` can turn a press into the row it fell on without a view.
pub const Row = struct {
    path: []const u8,
    name: []const u8,
    depth: u16,
    is_dir: bool,
};

pub const Sidebar = struct {
    /// Whether the panel is on screen. Closed to begin with: a window opens on
    /// its files.
    open: bool = false,

    /// Every indexed file, relative to the root, sorted by path. Owned here: the
    /// listing it was read from is let go of at once, so the tree does not
    /// depend on the library holding it.
    paths: std.ArrayList([]const u8) = .empty,

    /// The folders the reader has opened. A folder not in here is closed. Keys
    /// are owned, since the path they came from is a row that is rebuilt.
    expanded: std.StringHashMapUnmanaged(void) = .empty,

    /// How far the list is scrolled, in pixels. The view clamps it, since only
    /// the view knows how many rows there are and how tall it is.
    scroll: f32 = 0,

    /// Bumped whenever `paths` or `expanded` changes, so the fold and the glyphs
    /// shaped from it are known stale without comparing them.
    revision: u32 = 0,

    /// The strip the tree is drawn in, written by `place`.
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    /// The flat listing folded into a hierarchy, top to bottom, and a shaped line
    /// for each -- parallel, so `layouts[i]` is `rows[i]` in glyphs. `place`
    /// folds them when `built` falls behind `revision` and shapes the ones on
    /// screen; `update` hit-tests them and `draw` paints them.
    rows: std.ArrayList(Row) = .empty,
    layouts: std.ArrayList(LineLayout) = .empty,
    built: ?u32 = null,

    /// The two folder markers, shaped once each.
    chevron_open: LineLayout = .{},
    chevron_shut: LineLayout = .{},

    /// Lets go of the listing, keeping the folders the reader opened: closing
    /// the panel need not forget which folders were open, and re-reading the
    /// tree must not leak the last read.
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

    /// Owned by the renderer, which outlives everything that draws through it.
    ///
    /// Not const, and cannot be: shaping a line nobody has shaped before puts
    /// its glyphs in, so drawing a file for the first time writes here.
    ///
    /// Undefined until `run` has a window, because there is no atlas before
    /// there is one. Nothing between here and there places, draws or measures.
    atlas: *GlyphAtlas = undefined,

    /// The tab bar's band, and the unsaved-mark glyph every tab shares, both
    /// written by `place`. Layout is the mutable pass, and where the bar sits is
    /// what turns a press into the tab it fell on -- which `update` reads here
    /// rather than from a view. Each tab's own rect is on the file it names,
    /// `OpenFile.tab_rect`, since a file has at most one tab.
    tabs_rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    tab_bullet: LineLayout = .{},

    /// The file a save dialog was opened for, while it is open.
    ///
    /// The answer comes back on an event rather than from a call, so the focus
    /// can have moved by the time it does -- and the file can have been closed,
    /// which is why this is checked against the open files rather than trusted.
    naming: ?*OpenFile = null,

    /// Every file this window has open, in the order they were opened, which is
    /// also the order the bar lists them in.
    ///
    /// Owned here and nowhere else. A column points at one rather than holding
    /// it, so looking away from a file costs nothing and gives nothing up: the
    /// buffer, the line index, every line already shaped and the caret are all
    /// still here when it comes back. A file no column is pointing at is open
    /// and out of sight, which is the whole of what used to be a separate set.
    ///
    /// Boxed, because both the bar and the columns keep pointers into this and
    /// the list moves as it grows.
    files: std.ArrayList(*OpenFile) = .empty,

    /// Which files are on screen, left to right. Every one of these is in
    /// `files` as well; a file in `files` and not here is open and out of
    /// sight, which is all being "closed" ever meant short of closing.
    columns: std.ArrayList(*OpenFile) = .empty,

    /// Which column has the keyboard, and which has the pointer while a press
    /// is being held. Both are indices into `columns`.
    focus: usize = 0,
    holding: ?usize = null,

    /// The scratch preview, while there is one. A file opened from the finder or
    /// the tree lands here rather than on a tab of its own: the next file opened
    /// takes its place, so browsing does not leave a trail of tabs behind. It is
    /// promoted -- this goes null, the tab becomes its own -- the moment the file
    /// is edited or its tab is double-clicked.
    ///
    /// A pointer, so `close` can clear it and nothing is left pointing at a freed
    /// file. Null is the common case: nothing typed on the command line is a
    /// preview, and an edited one is not one any more.
    preview: ?*OpenFile = null,

    /// The library, and the index it keeps of the directory yaz was run in.
    /// Opened once, at startup, which is also where it was settled that it
    /// loads. Null only in a window that has no finder -- the healthcheck.
    library: ?fff.Library = null,
    index: ?fff.Index = null,

    /// The finder, while it is open.
    finding: ?Finding = null,

    /// The sidebar tree: open or not, and the listing behind it.
    sidebar: Sidebar = .{},

    /// The subscription that keeps the tree live, while there is one. Held so it
    /// can be let go when the panel closes: a watch on a tree nobody is looking
    /// at is wakeups for nothing.
    watch_id: ?u64 = null,

    /// Whether anything above has changed since the last frame was drawn.
    ///
    /// One flag for the whole model rather than one per component: what a
    /// window has to decide is whether to draw at all, and presenting blocks,
    /// so a redundant frame costs latency rather than just work. True to begin
    /// with, since the first frame has never been drawn.
    dirty: bool = true,

    /// False ends the window. Here rather than in the loop that reads it
    /// because what decides it is a component: the last file being closed is
    /// the end of the window, and only the thing holding the files knows that.
    running: bool = true,

    /// Nothing is open yet and there is no atlas yet: the first is `main`
    /// reading the command line, the second needs a window. Both arrive from
    /// outside, and nothing draws in between.
    pub fn init(process: std.process.Init) Model {
        return .{ .allocator = process.gpa, .io = process.io };
    }

    /// The atlas, once there is a window to have made one. Called once, before
    /// anything is placed or drawn.
    pub fn attach(self: *Model, atlas: *GlyphAtlas) void {
        self.atlas = atlas;
    }

    /// Opens the library and starts indexing the directory yaz was run in.
    ///
    /// The walk happens on a thread of the library's own, so this returns
    /// before it has finished and the window goes up while it is still
    /// counting. A cmd+P in that first moment searches what has been found so
    /// far, which is why nothing here waits.
    pub fn locate(self: *Model, environ: std.process.Environ) !void {
        const where = try tools.path(self.allocator, environ, .fff);
        defer self.allocator.free(where);

        // Known to load: startup refused to get this far otherwise.
        self.library = try fff.Library.open(where);
        self.index = try self.library.?.index(".");
    }

    /// Opens the finder. There is nothing to read: the index is already there
    /// and has been kept up to date since the window opened.
    ///
    /// One search with nothing typed, for the count alone. It is what the panel
    /// says before a query narrows it, and asking is how many files the index
    /// holds -- which the watcher moves while nobody is looking.
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

    /// Everything that only exists while the finder is open, which is now the
    /// query and the answer to it. The index outlives the panel.
    fn stopFinding(self: *Model) void {
        const finding = &(self.finding orelse return);
        finding.typed.deinit(self.allocator);
        if (finding.found) |*found| found.deinit();
        self.finding = null;
        self.changed();
    }

    /// Adds to the query and re-ranks against it.
    fn typeInto(self: *Model, text: []const u8) !void {
        const finding = &(self.finding orelse return);
        try finding.typed.appendSlice(self.allocator, text);
        try self.rank();
    }

    /// Takes a character back off the query. One byte at a time is wrong the
    /// moment the query is not ASCII, and `Buffer.stepBack` is where that is
    /// already solved; this is a query, not a file, and cannot reach it.
    fn rubOut(self: *Model) !void {
        const finding = &(self.finding orelse return);
        if (finding.typed.items.len == 0) return;
        finding.typed.items.len -= 1;
        try self.rank();
    }

    /// Moves the selection, and the window on to it, by one.
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

    /// Asks the index for what matches the query.
    ///
    /// Nothing typed is nothing offered: the whole repository is not an answer,
    /// and shaping a screenful of it would be work done on the way to being
    /// thrown away.
    ///
    /// This used to spawn fzf and write the whole listing to it, on every
    /// keystroke. It is now a call into a library holding the tree already.
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

    /// What `update` answers with: the model as it now is, and whatever is left
    /// for the runtime to go and do about the world outside it.
    ///
    /// The model comes back rather than being written through a pointer. Most
    /// of what it holds is behind one -- a document is a `*OpenFile` and its
    /// text is a gap buffer -- so this is value semantics over a handle rather
    /// than over the state, and there is only ever one live copy. What it does
    /// buy is that nothing can move the model except by being handed the result.
    pub const Answer = struct { Model, ?Effect };

    /// The one place anything here changes: a message in, the model and whatever
    /// is left for the runtime out.
    ///
    /// A raw pointer message it cannot act on directly -- a press, a drag, a
    /// wheel -- it hands to `resolve`, which reads the layout `place` left and
    /// answers with a message that says what was under the pointer; `update` then
    /// calls itself with that. So a click becomes a caret or a tab or a folder
    /// without anything outside the model knowing where things were drawn.
    ///
    /// Every branch that falls through asks for a frame once, at the bottom;
    /// those that answer early or with an effect ask for it themselves.
    pub fn update(start: Model, msg: Message) !Answer {
        var self = start;

        // Window-wide, whatever is in front of it.
        switch (msg) {
            .none => return .{ self, null },
            .quit => {
                self.running = false;
                return .{ self, null };
            },
            // Nothing moved but the room did, which only a redraw answers.
            .resized => {
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

                // Looked for among the open ones rather than trusted: the
                // answer arrives whenever the dialog is done with, and cmd+W
                // can have closed and freed the file in between.
                if (self.indexOf(file) == null) return .{ self, null };

                const owned = try self.allocator.dupe(u8, path);
                if (file.path) |old| self.allocator.free(old);
                file.path = owned;
                self.changed();

                // Written whether it was changed or not: being asked where to
                // put a file is being asked to put it there.
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

        // A raw pointer message is turned into what it landed on, and acted on.
        switch (msg) {
            .press, .move, .release, .wheel, .look => return self.update(self.resolve(msg)),
            else => {},
        }

        switch (msg) {
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
                // Typing over a selection replaces it, which is the one thing
                // every editor agrees on.
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
                // Putting the caret in a column is choosing that column, which
                // is why a press does not have to say both.
                self.focus = where.column;
                // A press that lands a caret is also the pointer taking hold:
                // the drag that may follow belongs to this column wherever it
                // wanders, and the release is what lets go. A drag says the
                // same thing again, which changes nothing.
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
                // A look can land the selection anywhere; bringing the view to
                // it is the rest of jumping there. A drag leaves this alone.
                if (what.follow) file.follow_caret = true;
                // And the pointer with it, so looking again from a still hand
                // steps on to the next occurrence.
                if (what.warp) file.warp_caret = true;
            },
            .scroll => |where| {
                const file = self.column(where.column) orelse return .{ self, null };
                file.pending = where.pending;
                // The fraction moved and nothing else did, so there is nothing
                // to draw: the window stays as it is until a whole pixel of it
                // has been asked for.
                if (file.scroll == where.to) return .{ self, null };
                file.scroll = where.to;
            },
            .grab => |where| {
                const file = self.column(where.column) orelse return .{ self, null };
                self.focus = where.column;
                // Held until the release, so a drag that wanders out of the
                // column it began in stays with it.
                self.holding = if (where.at == null) null else where.column;
                file.drag = where.at;
            },
            .focus => |which| self.focus = which,

            // The clipboard and the file are the runtime's; here they are named
            // by the column with the keyboard. Cut is a copy and a delete, the
            // delete done now and the copy left for the runtime.
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
                    // Asked for rather than refused. Which file is waiting is
                    // remembered here because the answer arrives whenever the
                    // dialog is done with, long after this has returned.
                    self.naming = file;
                    return .{ self, .ask_name };
                }
                // Nothing to write and nothing to say: what is on disk is
                // already what is on screen.
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

            // Opening reads the tree and asks for a watch; closing lets both go.
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

            // Reached only as a raw message the branches above did not want,
            // which is nothing to act on.
            else => return .{ self, null },
        }

        // A scratch preview that has been edited is a file the reader means to
        // keep. Read once, here, rather than in every branch that can edit:
        // being changed is exactly what the mark on its tab already says.
        if (self.preview) |file| {
            if (file.modified) self.preview = null;
        }

        self.changed();
        return .{ self, null };
    }

    /// What a raw pointer message means, once the layout `place` left is read:
    /// the tree row, the tab, or the place in a column it fell on. Answered as a
    /// message `update` calls itself with, so the geometry lives here and the
    /// acting lives there. A press that lands on nothing in a column still moves
    /// the keyboard to it.
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
                const asked = self.columnResolve(which, msg);
                return switch (asked) {
                    .none => .{ .focus = which },
                    else => asked,
                };
            },
            // Only while the pointer is held: a drag stays with the column it
            // began in wherever it wanders, and a bare hover reaches no column.
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

    /// Asks the nth column what a pointer message means in it, from the rect
    /// `place` gave it. The view is made on the spot: it keeps nothing between
    /// frames that the file does not already hold.
    fn columnResolve(self: *const Model, which: usize, msg: Message) Message {
        const file = self.column(which) orelse return .none;
        const view: TextView = .init(which, file, file.rect);
        return view.resolve(self, msg);
    }

    /// Which column a point fell in, if any.
    fn columnAt(self: *const Model, at: [2]f32) ?usize {
        for (self.columns.items, 0..) |file, which| {
            if (file.rect.contains(at)) return which;
        }
        return null;
    }

    /// Writes a file back to the path it was opened from.
    ///
    /// Through a temporary beside it and a rename over the top, so that a write
    /// that fails part way through leaves the file that was already there
    /// rather than half of a new one. `tools.install` follows the same rule for
    /// the same reason.
    ///
    /// The temporary is beside the file rather than anywhere tidier because a
    /// rename is only atomic within one filesystem, and the directory the file
    /// is in is the one place guaranteed to be on the same one.
    pub fn writeOut(self: *const Model, file: *OpenFile) !void {
        const path = file.path.?;

        // One slice of the whole file, which copies it when the gap divides it.
        // A save is rare and already about to write every byte, so a memcpy of
        // them on the way is not what it costs.
        const text = try file.buffer.slice(0, file.buffer.byteLen());

        const restored = if (file.crlf) try withCarriageReturns(self.allocator, text) else null;
        defer if (restored) |owned| self.allocator.free(owned);

        // A bare name is in the working directory, which is what "." is.
        const where = std.fs.path.dirname(path) orelse ".";
        const name = std.fs.path.basename(path);

        var dir = try std.Io.Dir.cwd().openDir(self.io, where, .{});
        defer dir.close(self.io);

        // Hidden and named for what wrote it, so an interrupted save leaves
        // something a person can recognise rather than wonder about.
        const partial = try std.fmt.allocPrint(self.allocator, ".{s}.yaz", .{name});
        defer self.allocator.free(partial);
        errdefer dir.deleteFile(self.io, partial) catch {};

        try dir.writeFile(self.io, .{ .sub_path = partial, .data = restored orelse text });
        try dir.rename(partial, dir, name, self.io);
    }

    /// The file the nth column is showing. Public because performing an effect
    /// needs it and performing one happens outside.
    pub fn column(self: *const Model, which: usize) ?*OpenFile {
        if (which >= self.columns.items.len) return null;
        return self.columns.items[which];
    }

    /// Puts the selection on the system clipboard.
    ///
    /// Nothing selected leaves the clipboard as it was. Cutting nothing should
    /// not throw away what somebody put there.
    ///
    /// SDL's clipboard is a C string either way, so a file holding a zero byte
    /// copies as far as the first one. Nothing here can do better without
    /// leaving the API SDL offers.
    pub fn copyOut(self: *Model, which: usize) !void {
        const file = self.column(which) orelse return;
        const chosen = file.selected();
        if (chosen.empty()) return;

        // Terminated for SDL, which copies what it is given: the buffer's own
        // slice is neither terminated nor good past the next call into it.
        const text = try file.buffer.slice(chosen.from, chosen.to);
        const owned = try self.allocator.dupeZ(u8, text);
        defer self.allocator.free(owned);

        if (!c.SDL_SetClipboardText(owned.ptr)) {
            std.log.err("SDL_SetClipboardText: {s}", .{sdl.lastError()});
        }
    }

    /// What is on the system clipboard, with its line endings mended, or none
    /// when there is nothing there. Caller owns the result.
    ///
    /// Reading it is the runtime's; typing it in is an `.insert` message like
    /// any other keystroke, which is why this hands the text back rather than
    /// putting it anywhere.
    pub fn clipboard(self: *const Model) !?[]u8 {
        // A copy SDL made and wants back. Empty rather than null when there is
        // nothing on the clipboard, which is not an error.
        const given = c.SDL_GetClipboardText();
        if (given == null) return null;
        defer c.SDL_free(given);

        const text = std.mem.span(given);
        if (text.len == 0) return null;

        return try unixEndings(self.allocator, text) orelse
            try self.allocator.dupe(u8, text);
    }

    /// Takes out whatever is selected and answers where the caret ends up.
    ///
    /// Nothing selected removes nothing and leaves the caret where it was, so
    /// everything that edits can call this first and not ask.
    fn dropSelection(file: *OpenFile) !usize {
        const chosen = file.selected();
        if (chosen.to == chosen.from) return file.cursor;

        _ = try file.delete(chosen.from, chosen.to - chosen.from);
        file.cursor = chosen.from;
        file.anchor = chosen.from;
        return chosen.from;
    }

    /// Says the model has moved on and the window has to be drawn again.
    fn changed(self: *Model) void {
        self.dirty = true;
    }

    /// The nth file on the bar, or none when the bar is shorter than that. A
    /// file nobody named has no tab, so it is not counted.
    fn tab(self: *const Model, which: usize) ?*OpenFile {
        var counted: usize = 0;
        for (self.files.items) |file| {
            if (file.path == null) continue;
            if (counted == which) return file;
            counted += 1;
        }
        return null;
    }

    /// Shows the nth file on the bar and nothing else: every other column goes
    /// back to being open but not on screen.
    ///
    /// Choosing one of something is choosing it instead of the rest, which is
    /// what makes this the plain binding and `cmd+alt` the one that adds.
    fn showOnly(self: *Model, nth: usize) !void {
        const wanted = self.tab(nth) orelse return;
        self.columns.clearRetainingCapacity();
        try self.columns.append(self.allocator, wanted);
        self.focus = 0;
    }

    /// Puts the nth file on the bar beside what is already there, or takes it
    /// away again when it is already there.
    ///
    /// Taking one away is not closing it: the file stays on the bar with its
    /// caret where it was, so putting it back costs nothing. The last column
    /// cannot go -- something has to be there to type into.
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

    /// Takes the file the focused column is showing out of the window and out
    /// of memory, and puts something else in the column.
    ///
    /// The column takes the first file nothing else is showing, so closing
    /// walks back through what is open; when the last file goes the column falls
    /// back to a blank, which is where a window with no file named starts. So
    /// the window does not close on its last file -- it empties.
    ///
    /// The one thing that does close it is closing that blank in turn: an empty
    /// window, closed, is the way out. cmd+W on a window that was never given a
    /// file is the same keystroke and means the same thing.
    fn shut(self: *Model) !void {
        const closing = self.showing() orelse return;

        // The last thing in the window is a blank: closing it is closing the
        // window. Closing the last *named* file falls through instead, to the
        // blank it leaves behind.
        if (self.files.items.len == 1 and closing.path == null) {
            self.running = false;
            return;
        }

        // One fewer column to split into. The last one stays, because
        // something has to be there to type into.
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

    /// Opens what the finder has selected, in the column with the keyboard, and
    /// puts the finder away. Picking a file is the end of picking.
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

    /// Opens `path` in the column with the keyboard, or moves to it when it is
    /// already on screen. What the finder does with what it chose, and what the
    /// tree does with what was clicked.
    ///
    /// A file opened this way is a scratch preview: the file the focused column
    /// was showing is kept as a tab, unless it was itself the preview, in which
    /// case it is closed and the new file takes the tab it had. So opening one
    /// file after another leaves one tab, not a row of them, until one is kept.
    fn openInFocus(self: *Model, path: []const u8) !void {
        // Asked before opening, since opening it is what would put it there:
        // reopening a file that is already a tab is not the same as browsing to
        // a new one, and does not turn a kept tab back into a preview.
        const fresh = self.opened(path) == null;
        const wanted = try self.open(path);

        // Already on screen: move to it and leave the scratch tab as it is.
        if (self.columnOf(wanted)) |which| {
            self.focus = which;
            return;
        }

        // What the focused column is about to stop showing. It is off screen
        // once the new file is in, since a file is in at most one column.
        const leaving = self.column(self.focus);

        if (self.focus < self.columns.items.len) {
            self.columns.items[self.focus] = wanted;
        } else {
            try self.columns.append(self.allocator, wanted);
            self.focus = self.columns.items.len - 1;
        }

        // The scratch tab the column just left is done: the new file takes it.
        // `close` clears `preview` as it frees, so nothing points at it after.
        if (leaving) |gone| {
            if (gone == self.preview) self.close(gone);
        }

        // A freshly opened file is the new scratch preview. A reopened one is a
        // tab the reader already meant to keep, so it is not.
        if (fresh) self.preview = wanted;
    }

    /// Promotes the nth tab out of being the scratch preview, so the next file
    /// opened does not replace it. What double-clicking a tab asks for, and what
    /// editing a previewed file does on its own.
    fn pin(self: *Model, which: usize) void {
        const file = self.tab(which) orelse return;
        if (self.preview == file) self.preview = null;
    }

    /// Re-reads the whole tree into `sidebar.paths`, sorted by path. What every
    /// change on disk comes back to, and what opening the panel does first.
    ///
    /// The listing is let go of at once: the paths are copied out, so the tree
    /// does not hold the library's answer for as long as it is on screen.
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

    /// Opens a folder that is closed, or closes one that is open. The key is
    /// copied on the way in, since the path it came from is a row the next
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

    /// Subscribes to changes under the root, so the tree stays live while it is
    /// open. Reported rather than returned: a watch that will not start is a
    /// tree that does not update on its own, not a window that cannot go up.
    ///
    /// The effect the `.toggle_tree` message asks for. Performed outside the
    /// model because the callback it registers pushes an SDL event.
    pub fn watchTree(self: *Model) void {
        const index = self.index orelse return;
        if (self.watch_id != null) return;
        self.watch_id = index.watch(onDiskChange, null) catch |err| {
            std.log.err("sidebar watch: {s}", .{@errorName(err)});
            return;
        };
    }

    /// Lets the subscription go. A no-op when there is none, so it is safe to
    /// call on the way out whether the tree was ever opened or not.
    pub fn unwatchTree(self: *Model) void {
        const index = self.index orelse return;
        const id = self.watch_id orelse return;
        index.unwatch(id);
        self.watch_id = null;
    }

    /// What the column with the keyboard is showing, or none before there is a
    /// column. Asked rather than stored: it is `columns` and `focus`, and two
    /// facts that agree by construction cannot drift.
    pub fn showing(self: *const Model) ?*OpenFile {
        if (self.focus >= self.columns.items.len) return null;
        return self.columns.items[self.focus];
    }

    /// Whether a column is showing `file`. The bar asks this of every file it
    /// lists, which is few enough that a walk is the whole of it.
    pub fn onScreen(self: *const Model, file: *const OpenFile) bool {
        for (self.columns.items) |shown| {
            if (shown == file) return true;
        }
        return false;
    }

    /// Which column is showing `file`, if one is.
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

    /// The file called `path`, opened if it is not open already.
    ///
    /// Asking twice gives the same file back, which is what stops two columns
    /// showing two copies of one file that drift apart.
    /// Opens a file, or hands back the one already open on that path. Public
    /// for `main`, which opens what the command line named; the finder reaches
    /// it through `choose`.
    pub fn open(self: *Model, path: []const u8) !*OpenFile {
        if (self.opened(path)) |already| return already;

        const was = try self.read(path);
        defer self.allocator.free(was.text);
        return self.hold(was.text, path, was.crlf);
    }

    /// A file nobody named, which is what a window with nothing to show has.
    /// A file with nothing in it and no name. Public for the same reason as
    /// `open`: a window has to have something in it, and `main` is where that
    /// is decided when the command line named nothing.
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

    /// Out of the window and out of memory. Closing is the one thing that means
    /// a file is finished with.
    fn close(self: *Model, file: *OpenFile) void {
        // Nothing may point at it once it is freed, and the scratch preview is
        // the one thing besides a column that might.
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

        // What it came in as, so that saving can put it back that way.
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

/// Orders two paths for the tree's listing. Bytewise, which puts a folder's
/// files in the order they read and is what the view folds a hierarchy out of.
fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// What the library's watcher calls when the tree changes, on a thread of its
/// own. So it touches nothing but what is safe from anywhere: it wakes the
/// window, and lets the batch go.
///
/// Which paths changed is not read. The library has already folded them into
/// its index by the time this runs, and the tree re-reads that whole rather
/// than acting on one path, so the batch is freed unlooked-at.
fn onDiskChange(_: u64, batch: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    sdl.pushTreeChanged();
    if (batch) |owned| fff.freeWatchEvents(owned);
}

/// An offset rather than a yes or no, because the offset is the part a caller
/// can act on.
///
/// Worth refusing over rather than drawing: HarfBuzz would substitute a
/// replacement character and only look wrong, but `stepBack` walks continuation
/// bytes until it finds one that is not, so backspace over stray bytes deletes
/// however many happen to be adjacent.
fn firstInvalidUtf8(text: []const u8) ?usize {
    // Not `utf8ValidateSlice` first with this only on failure: that is two
    // pieces of code deciding what UTF-8 is, and the day they disagreed the
    // fast path would say no and this would find nothing to point at.
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

/// Turns CRLF into LF, freeing what it is given only if it has to replace it.
///
/// A carriage return is not a line break to the line index, so it would reach
/// the shaper and set as .notdef at the end of every line. The bytes then stop
/// matching the file exactly, which is a trade to revisit when there is a way
/// to save.
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

/// What came back from reading a file: the text, and whether its lines ended
/// with a carriage return before they were taken out.
///
/// Carried rather than worked out again later. The returns are gone from the
/// text by the time anything else sees it, so this is the only chance to know.
const Read = struct {
    text: []u8,
    crlf: bool,
};

/// The text with a carriage return in front of every newline, which is how a
/// file that came in with them goes back out.
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

/// Clipboard text with its line endings made into the one the line index
/// counts, or null when it already has them.
///
/// Windows puts CRLF on the clipboard and SDL hands it over unchanged; older
/// Mac text is a bare CR. Only `\n` starts a line here, so either would land in
/// the file as a byte with nothing on screen to account for it -- a glyph at
/// the end of every pasted line, and a column count nobody could explain.
///
/// Null rather than a copy when there is nothing to mend, which is every paste
/// that came from another window of this editor.
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

/// Moves the model and puts it back down, which is what `App.update` does, and
/// hands back whatever was left for the runtime to do. Most of the tests below
/// have nothing left and ignore it.
fn moved(model: *Model, change: Message) !?Effect {
    const next, const effect = model.update(change) catch |err| return err;
    model.* = next;
    return effect;
}

/// As much of the runtime's half as a test can do. The clipboard and the dialog
/// need a window; writing a file does not.
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

/// Both halves, for the tests that want the whole round trip.
fn moveAndPerform(model: *Model, change: Message) !void {
    if (try moved(model, change)) |effect| try performed(model, effect);
}

/// A model with one file in one column, which is what the tests below all want
/// and none of them varies. The io is never reached: nothing here reads or
/// writes anything.
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

/// What the one file holds, which is the only thing these tests read back.
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

    // The caret lands after what was typed, with nothing selected: a
    // replacement is one edit, not a selection that survives it.
    const file = model.columns.items[0];
    try std.testing.expectEqual(@as(usize, 7), file.cursor);
    try std.testing.expect(!file.hasSelection());
}

test "backspace over a selection takes the selection and no more" {
    var model = try oneOpenFile(std.testing.allocator, "one two three");
    defer model.deinit();

    _ = try moved(&model, .{ .selection = .{ .column = 0, .from = 4, .to = 7 } });
    _ = try moved(&model, .backspace);

    // The space before `two` is still there: backspacing a selection is not
    // backspacing a selection and then a character.
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
/// The tests below are the only place anything here writes anything.
fn oneSavedFile(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !Model {
    var model = try oneOpenFile(allocator, text);
    errdefer model.deinit();

    model.io = std.testing.io;
    model.columns.items[0].path = try allocator.dupe(u8, path);
    return model;
}

/// Where a temporary directory sits, said the way the working directory sees
/// it: `writeOut` opens the directory a path names, so the path has to be one.
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

    // Not even created: a save that had nothing to do did nothing.
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
    // Asked and answered: nothing is still waiting for a name.
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

    // The old path is let go of rather than leaked, which the testing
    // allocator is what checks.
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

    // Still up, now showing a single blank where the file was.
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
    // A blank, which is what a window opened with no path shows.
    var model = try oneOpenFile(allocator, "");
    defer model.deinit();

    _ = try moved(&model, .close);
    try std.testing.expect(!model.running);
}

/// A window on a blank, with an io to open files by. The names below do not
/// exist, so opening one is an empty file with that path -- which is all these
/// tests read of it.
fn browsing(allocator: std.mem.Allocator) !Model {
    var model = try oneOpenFile(allocator, "");
    errdefer model.deinit();
    model.io = std.testing.io;
    return model;
}

/// Whether a file with `path` is still open.
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
    // The file just opened is the preview, and it is what the column shows.
    try std.testing.expect(model.preview == model.showing().?);
    try std.testing.expect(isOpen(&model, "scratch-a.zzz"));

    _ = try moved(&model, .{ .open_file = "scratch-b.zzz" });
    // The second takes the first's place: the first is gone, not left on a tab.
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
    // Both are open now: the edited one was kept.
    try std.testing.expect(isOpen(&model, "scratch-a.zzz"));
    try std.testing.expect(isOpen(&model, "scratch-b.zzz"));
}

test "double-clicking a tab keeps it out of being replaced" {
    const allocator = std.testing.allocator;
    var model = try browsing(allocator);
    defer model.deinit();

    _ = try moved(&model, .{ .open_file = "scratch-a.zzz" });
    try std.testing.expect(model.preview != null);

    // The blank has no tab, so the opened file is the first and only one on the
    // bar. Pinning it is what a double-click asks for.
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
