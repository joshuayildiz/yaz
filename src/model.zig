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
const open_file = @import("./open_file.zig");
const OpenFile = open_file.OpenFile;
const Span = open_file.Span;
const tools = @import("./tools.zig");
const sdl = @import("./sdl.zig");
const c = sdl.c;
const fff = @import("./fff.zig");
const Effect = @import("./message.zig").Effect;

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

    /// The window, for the one thing that needs one from here: a save dialog is
    /// modal to a window or it is loose on the desktop. Null in a model that
    /// never had one, which is every test.
    window: ?*c.SDL_Window = null,

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

    /// The library, and the index it keeps of the directory yaz was run in.
    /// Opened once, at startup, which is also where it was settled that it
    /// loads. Null only in a window that has no finder -- the healthcheck.
    library: ?fff.Library = null,
    index: ?fff.Index = null,

    /// The finder, while it is open.
    finding: ?Finding = null,

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
    pub fn attach(self: *Model, atlas: *GlyphAtlas, window: *c.SDL_Window) void {
        self.atlas = atlas;
        self.window = window;
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

    /// The other half of `Effect`: the one place anything here changes.
    ///
    /// Every branch is a change, so the frame is asked for once, here, rather
    /// than by each of them remembering to. `nothing` is the only thing that
    /// leaves the window as it was.
    pub fn apply(self: *Model, effect: Effect) !void {
        switch (effect) {
            .nothing => return,
            .nothing_but_draw => {},

            .quit => self.running = false,

            .insert => |what| {
                const file = self.column(what.column) orelse return;
                // Typing over a selection replaces it, which is the one thing
                // every editor agrees on.
                const at = try dropSelection(file);
                _ = try file.insert(at, what.text);
                file.cursor = at + what.text.len;
                file.anchor = file.cursor;
                file.follow_caret = true;
            },
            .backspace => |which| {
                const file = self.column(which) orelse return;
                if (file.hasSelection()) {
                    _ = try dropSelection(file);
                } else {
                    const from = file.buffer.stepBack(file.cursor);
                    if (from == file.cursor) return;
                    _ = try file.delete(from, file.cursor - from);
                    file.cursor = from;
                    file.anchor = from;
                }
                file.follow_caret = true;
            },
            .caret => |where| {
                const file = self.column(where.column) orelse return;
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
                const file = self.column(what.column) orelse return;
                self.focus = what.column;
                const end = file.buffer.byteLen();
                file.anchor = @min(what.from, end);
                file.cursor = @min(what.to, end);
            },
            .scroll => |where| {
                const file = self.column(where.column) orelse return;
                file.pending = where.pending;
                // The fraction moved and nothing else did, so there is nothing
                // to draw: the window stays as it is until a whole pixel of it
                // has been asked for.
                if (file.scroll == where.to) return;
                file.scroll = where.to;
            },
            .grab => |where| {
                const file = self.column(where.column) orelse return;
                self.focus = where.column;
                // Held until the release, so a drag that wanders out of the
                // column it began in stays with it.
                self.holding = if (where.at == null) null else where.column;
                file.drag = where.at;
            },

            .copy => |which| {
                try self.copyOut(which);
                // The clipboard is not drawn, so nothing on screen moved.
                return;
            },
            .cut => |which| {
                try self.copyOut(which);
                const file = self.column(which) orelse return;
                if (!file.hasSelection()) return;
                _ = try dropSelection(file);
                file.follow_caret = true;
            },
            .paste => |which| try self.pasteIn(which),
            .name_it => |path| try self.nameAndSave(path),
            .save => |which| {
                const file = self.column(which) orelse return;
                if (file.path == null) {
                    // Asked for rather than refused. The answer arrives later,
                    // on an event, because the dialog does not block and its
                    // callback is not promised a thread.
                    self.naming = file;
                    sdl.askWhereToSave(self.window);
                    return;
                }
                // Nothing to write and nothing to say: the file on disk is
                // already what is on screen.
                if (!file.modified) return;

                // Reported rather than returned. A file that cannot be written
                // -- read-only, no room, a directory gone -- is something to be
                // told about, and the mark staying on its tab is the rest of
                // the telling. An error here would take the window down.
                self.writeOut(file) catch |err| {
                    std.log.err("{s}: {s}", .{ file.path.?, @errorName(err) });
                };
                return;
            },

            .focus => |which| self.focus = which,
            .holding => |which| self.holding = which,

            .show => |nth| try self.showOnly(nth),
            .split => |nth| try self.split(nth),
            .close => try self.shut(),

            .find => try self.find(),
            .dismiss => self.stopFinding(),
            .query => |what| try self.typeInto(what),
            .rub => try self.rubOut(),
            .up => self.select(.up),
            .down => self.select(.down),
            .choose => try self.choose(),
        }
        self.changed();
    }

    /// Gives the file that asked for a name the one that came back, and writes
    /// it there.
    ///
    /// The file is looked for among the open ones rather than trusted: the
    /// answer arrives whenever the dialog is done with, and cmd+W can have
    /// closed and freed the file in between.
    fn nameAndSave(self: *Model, path: []const u8) !void {
        const file = self.naming orelse return;
        self.naming = null;
        if (self.indexOf(file) == null) return;

        const owned = try self.allocator.dupe(u8, path);
        if (file.path) |old| self.allocator.free(old);
        file.path = owned;

        // Written whether it was changed or not: being asked where to put a
        // file is being asked to put it there.
        self.writeOut(file) catch |err| {
            std.log.err("{s}: {s}", .{ path, @errorName(err) });
        };
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
    fn writeOut(self: *Model, file: *OpenFile) !void {
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

        file.modified = false;
    }

    /// Puts the selection on the system clipboard.
    ///
    /// Nothing selected leaves the clipboard as it was. Cutting nothing should
    /// not throw away what somebody put there.
    ///
    /// SDL's clipboard is a C string either way, so a file holding a zero byte
    /// copies as far as the first one. Nothing here can do better without
    /// leaving the API SDL offers.
    fn copyOut(self: *Model, which: usize) !void {
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

    /// Puts what is on the system clipboard into the file, over the selection
    /// if there is one.
    fn pasteIn(self: *Model, which: usize) !void {
        const file = self.column(which) orelse return;

        // A copy SDL made and wants back. Empty rather than null when there is
        // nothing on the clipboard, which is not an error.
        const given = c.SDL_GetClipboardText();
        if (given == null) return;
        defer c.SDL_free(given);

        const text = std.mem.span(given);
        if (text.len == 0) return;

        const mended = try unixEndings(self.allocator, text);
        defer if (mended) |owned| self.allocator.free(owned);
        const putting = mended orelse text;

        const at = try dropSelection(file);
        _ = try file.insert(at, putting);
        file.cursor = at + putting.len;
        file.anchor = file.cursor;
        file.follow_caret = true;
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

    /// The file the nth column is showing.
    fn column(self: *const Model, which: usize) ?*OpenFile {
        if (which >= self.columns.items.len) return null;
        return self.columns.items[which];
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
    /// of memory, and puts something else in the column. With nothing left on
    /// the bar the window goes too.
    ///
    /// The column takes the first file nothing else is showing, so closing
    /// walks back through what is open; when there is nothing left it goes
    /// empty, which is where a window with no file named starts.
    fn shut(self: *Model) !void {
        const closing = self.showing() orelse return;

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

        // Nothing open is nothing to come back to. It is also where a window
        // that was never given a file starts, so cmd+W on one of those is a way
        // out rather than a keystroke that does nothing.
        for (self.files.items) |file| {
            if (file.path != null) break;
        } else self.running = false;
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

        const wanted = try self.open(path);
        if (self.columnOf(wanted)) |which| {
            self.focus = which;
        } else if (self.focus < self.columns.items.len) {
            self.columns.items[self.focus] = wanted;
        } else {
            try self.columns.append(self.allocator, wanted);
            self.focus = self.columns.items.len - 1;
        }
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
        const which = self.indexOf(file) orelse return;
        _ = self.files.orderedRemove(which);
        file.deinit();
        self.allocator.destroy(file);
    }

    /// Every file gives up what it had shaped, for after the atlas is rebuilt
    /// at a different scale. Asked of the context rather than of the components
    /// because a file nothing is showing has a tab, and its name is glyphs of
    /// the old size too.
    pub fn invalidate(self: *Model) void {
        for (self.files.items) |file| file.invalidate();
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

    try model.apply(.{ .selection = .{ .column = 0, .from = 4, .to = 7 } });
    try model.apply(.{ .insert = .{ .column = 0, .text = "six" } });

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

    try model.apply(.{ .selection = .{ .column = 0, .from = 4, .to = 7 } });
    try model.apply(.{ .backspace = 0 });

    // The space before `two` is still there: backspacing a selection is not
    // backspacing a selection and then a character.
    try std.testing.expectEqualStrings("one  three", try whatIsIn(&model));
    try std.testing.expectEqual(@as(usize, 4), model.columns.items[0].cursor);
}

test "backspace with no selection still takes the character before the caret" {
    var model = try oneOpenFile(std.testing.allocator, "one two");
    defer model.deinit();

    try model.apply(.{ .caret = .{ .column = 0, .at = 3 } });
    try model.apply(.{ .backspace = 0 });

    try std.testing.expectEqualStrings("on two", try whatIsIn(&model));
}

test "a press collapses the selection and a shifted one extends it" {
    var model = try oneOpenFile(std.testing.allocator, "one two three");
    defer model.deinit();
    const file = model.columns.items[0];

    try model.apply(.{ .caret = .{ .column = 0, .at = 4 } });
    try std.testing.expect(!file.hasSelection());

    // Shifted: the far end stays at 4 and only this end moves.
    try model.apply(.{ .caret = .{ .column = 0, .at = 7, .extend = true } });
    try std.testing.expectEqual(Span{ .from = 4, .to = 7 }, file.selected());

    // Unshifted: whatever was selected is let go of.
    try model.apply(.{ .caret = .{ .column = 0, .at = 9 } });
    try std.testing.expect(!file.hasSelection());
}

test "a selection past the end of the file is clamped to it" {
    var model = try oneOpenFile(std.testing.allocator, "one");
    defer model.deinit();

    try model.apply(.{ .selection = .{ .column = 0, .from = 0, .to = 99 } });
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

    try model.apply(.{ .insert = .{ .column = 0, .text = "kept\n" } });
    try std.testing.expect(file.modified);

    try model.apply(.{ .save = 0 });
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

    try model.apply(.{ .insert = .{ .column = 0, .text = "x" } });
    try model.apply(.{ .save = 0 });

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

    try model.apply(.{ .save = 0 });

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

    try model.apply(.{ .insert = .{ .column = 0, .text = "written" } });
    try model.apply(.{ .save = 0 });

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

    try model.apply(.{ .insert = .{ .column = 0, .text = "somewhere" } });

    // What the dialog's answer arriving looks like from here.
    model.naming = file;
    try model.apply(.{ .name_it = path });

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
    try model.apply(.{ .name_it = path });

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
    try model.apply(.{ .name_it = first });

    model.naming = file;
    try model.apply(.{ .name_it = second });

    // The old path is let go of rather than leaked, which the testing
    // allocator is what checks.
    try std.testing.expectEqualStrings(second, file.path.?);
}
