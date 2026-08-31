const std = @import("std");

const Renderer = @import("./renderer.zig").Renderer;
const displayScale = @import("./renderer.zig").displayScale;
const TextView = @import("./components/text_view.zig").TextView;
const Position = @import("./components/text_view.zig").Position;
const Retired = @import("./components/text_view.zig").Retired;
const Document = @import("./document.zig").Document;
const GlyphAtlas = @import("./glyph_atlas.zig").GlyphAtlas;
const event_mod = @import("./event.zig");
const Event = event_mod.Event;
const Intent = event_mod.Intent;
const Painter = @import("./painter.zig").Painter;
const Rect = @import("./painter.zig").Rect;
const sdl = @import("./sdl.zig");
const tools = @import("./tools.zig");
const Healthcheck = @import("./components/healthcheck.zig").Healthcheck;
const Finder = @import("./components/finder.zig").Finder;
const ZTuple = @import("./components/ztuple.zig").ZTuple;
const HList = @import("./components/hlist.zig").HList;
const VTuple = @import("./components/vtuple.zig").VTuple;
const Tabs = @import("./components/tabs.zig").Tabs;
const c = sdl.c;

/// The largest file yaz will open. What still costs per line of the document
/// rather than per line on screen is the layout cache, which holds a 64-byte
/// entry for each of them, and the line index behind it.
const file_limit = 1 << 20;

/// `setup` prints, so it has to be heard from in a release build too, where the
/// default would keep everything below an error to itself.
pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    if (try wantsSetup(init)) return setup(init);

    // The tools before anything else: with either of them missing nothing but
    // the healthcheck runs, and reading a file first would report the wrong
    // problem when the path is also bad.
    const absent = try tools.missing(init.gpa, init.io, init.minimal.environ);
    if (absent.any()) {
        return run(Stopped, init.gpa, init.io, .init(.{
            try Healthcheck.init(init.gpa, init.minimal.environ, absent),
        }));
    }

    // Read out here rather than inside `run`, so a file that cannot be opened
    // fails before a window has appeared and gone again. Nothing in a stack
    // needs a window to be built.
    var views = try openViews(init);
    errdefer views.deinit();

    var tabs: Tabs = .init(init.gpa);
    errdefer tabs.deinit();
    for (views.items.items) |view| {
        if (view.path) |named| try tabs.opened(named);
    }

    return run(Editing, init.gpa, init.io, .init(.{
        try Finder.init(init.gpa, init.io, init.minimal.environ),
        .init(.{ tabs, views }),
    }));
}

/// A column per file named, left to right in the order they were named.
fn openViews(init: std.process.Init) !Views {
    var opened = try openAll(init);
    defer {
        for (opened.items) |*file| file.deinit(init.gpa);
        opened.deinit(init.gpa);
    }

    var views: Views = .init(init.gpa);
    errdefer views.deinit();

    // Never empty: a document nobody named is still a document.
    try views.items.ensureTotalCapacity(init.gpa, opened.items.len);
    for (opened.items) |file| {
        try views.append(try TextView.init(init.gpa, file.text, file.path));
    }
    return views;
}

/// A file that is in memory but not on screen, and where its reader was in it.
const Parked = struct {
    document: Document,
    position: Position,

    /// By path, which is what the finder answers with. Keys are owned, and a
    /// document is either in here or in exactly one view, never both.
    const Map = std.StringHashMapUnmanaged(Parked);
};

/// The window when a tool is missing: one component, and nothing that could go
/// in front of it.
const Stopped = ZTuple(&.{Healthcheck});

/// Left to right, one per file named. A list rather than a tuple because how
/// many there are is not known until the command line has been read.
const Views = HList(TextView);

/// Top to bottom: a tab per file open in the window, and the columns under it.
/// The bar says how tall it is and the columns take the rest.
const Workspace = VTuple(&.{ Tabs, Views });

/// Back to front. The finder sits behind the workspace until cmd+P brings it
/// forward, so opening and closing it is a change of order and nothing else.
const Editing = ZTuple(&.{ Finder, Workspace });

/// The window, and whatever `main` decided goes in it.
///
/// Generic over the stack rather than holding one of each kind, so a component
/// that is not in this window does not exist in this build of it: the branches
/// below that name one are compiled out where there is none. The tool check
/// happens once, in `main`, and nothing here can ask again.
fn App(comptime Stack: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        io: std.Io,
        renderer: Renderer,
        painter: Painter,
        stack: Stack,

        /// Files that have been looked at and are not on screen now.
        ///
        /// Kept whole rather than re-read: a document is a buffer, a line index
        /// and every line already shaped, and looking away from a file is no
        /// reason to throw that away and pay for it again on the way back.
        ///
        /// Here rather than in the row because a row is a layout and knows
        /// nothing about documents, and because this is where a path picked in
        /// the finder arrives.
        parked: Parked.Map = .empty,

        running: bool = true,

        /// What has changed at this level, as against inside the stack. True to
        /// begin with: the first frame has never been drawn.
        dirty: bool = true,

        fn deinit(self: *Self) void {
            var resting = self.parked.iterator();
            while (resting.next()) |entry| {
                self.gpa.free(entry.key_ptr.*);
                entry.value_ptr.document.deinit();
            }
            self.parked.deinit(self.gpa);

            self.stack.deinit();
            self.painter.deinit();
            self.renderer.deinit();
        }

        fn isDirty(self: *const Self) bool {
            return self.dirty or self.stack.isDirty();
        }

        fn setDirty(self: *Self, value: bool) void {
            self.dirty = value;
            self.stack.setDirty(value);
        }

        /// Takes what belongs to the window and hands the rest to whatever is in
        /// front. What changed is not answered here; it is asked for afterwards,
        /// through `isDirty`.
        fn update(self: *Self, event: Event) !void {
            switch (event) {
                .quit => {
                    self.running = false;
                    return;
                },
                .resized => {
                    self.dirty = true;
                    return;
                },
                // The one thing that changes what is in front. Pressed again it
                // falls through to the finder itself, which asks to be put away
                // exactly as escape makes it.
                .close => if (comptime Stack.has(Workspace)) {
                    try self.shut();
                    return;
                },
                // The bar is not the thing with the keyboard, so this cannot
                // reach it by being routed; it is a binding on the window, the
                // same as cmd+P.
                .tab => |which| if (comptime Stack.has(Workspace)) {
                    const tabs = self.stack.get(Workspace).get(Tabs);
                    if (tabs.nth(which)) |path| {
                        try self.act(.{ .open = try self.gpa.dupe(u8, path) });
                    }
                    return;
                },
                .find => if (comptime Stack.has(Finder)) {
                    if (!self.stack.inFront(Finder)) {
                        try self.stack.get(Finder).show();
                        self.stack.raise(Finder);
                        self.dirty = true;
                        return;
                    }
                },
                else => {},
            }

            try self.act(try self.stack.update(event, &self.renderer.atlas));
        }

        /// Does what the component in front asked for and could not do itself,
        /// because only this knows what else is in the stack.
        fn act(self: *Self, intent: Intent) !void {
            switch (intent) {
                .nothing => {},
                .dismiss => {
                    self.stack.lowerFront();
                    self.dirty = true;
                },
                .open => |path| {
                    defer self.gpa.free(path);

                    // A panel that opens something is done with the screen. The
                    // tab bar is not a panel, and lowering the workspace would
                    // put the finder in front of it.
                    if (comptime Stack.has(Finder)) {
                        if (self.stack.inFront(Finder)) self.stack.lowerFront();
                    }

                    self.dirty = true;
                    if (comptime Stack.has(Workspace)) {
                        const workspace = self.stack.get(Workspace);
                        try self.reveal(path);

                        // Choosing a file is choosing to read it, so the
                        // keyboard follows it into the column it landed in --
                        // whether the choice came from the bar or from the
                        // finder, and wherever the press that made it happened.
                        workspace.focusOn(Views);
                    }
                },
            }
        }

        /// Puts `path` in front of the reader, in the view with the keyboard.
        ///
        /// A view already showing it is left alone rather than a second copy
        /// opened, which is both what one expects and the only way two views of
        /// one file cannot drift apart -- they share no document.
        fn reveal(self: *Self, path: []const u8) !void {
            const workspace = self.stack.get(Workspace);
            try workspace.get(Tabs).opened(path);

            const views = workspace.get(Views);
            for (views.items.items, 0..) |*view, which| {
                const named = view.path orelse continue;
                if (!std.mem.eql(u8, named, path)) continue;

                views.focus = which;
                return;
            }

            const view = views.focused() orelse return;

            var document: Document = undefined;
            var was: ?Position = null;

            if (self.parked.fetchRemove(path)) |entry| {
                // Looked at before: everything about it is still here.
                self.gpa.free(entry.key);
                document = entry.value.document;
                was = entry.value.position;
            } else {
                // Through `open`, so a file picked here meets the same rules as
                // one named on the command line: the size limit, the UTF-8
                // check, and CRLF turned into LF.
                var file = try open(self.gpa, self.io, path);
                defer file.deinit(self.gpa);
                document = try Document.init(self.gpa, file.text);
            }
            errdefer document.deinit();

            try self.park(try view.swap(document, path, was, &self.renderer.atlas));
        }

        /// Takes the file the focused column is showing off the bar and out of
        /// memory, and puts something else in the column.
        ///
        /// The column takes the first file nothing is showing, so closing walks
        /// back through what is open; when there is nothing left it goes empty,
        /// which is where a window with no file named starts.
        fn shut(self: *Self) !void {
            const workspace = self.stack.get(Workspace);
            const views = workspace.get(Views);
            const tabs = workspace.get(Tabs);

            const view = views.focused() orelse return;
            // A document nobody named has no tab, so there is nothing to close.
            const closing = view.path orelse return;

            var next: ?Parked.Map.KV = null;
            for (tabs.paths.items) |listed| {
                if (self.parked.fetchRemove(listed)) |entry| {
                    next = entry;
                    break;
                }
            }

            tabs.close(closing);

            var document: Document = undefined;
            var was: ?Position = null;
            var path: ?[]const u8 = null;
            if (next) |entry| {
                document = entry.value.document;
                was = entry.value.position;
                path = entry.key;
            } else {
                document = try Document.init(self.gpa, "");
            }
            errdefer document.deinit();

            var retired = try view.swap(document, path, was, &self.renderer.atlas);
            if (next) |entry| self.gpa.free(entry.key);

            // Not parked: closing is the one thing that means a document is
            // finished with.
            if (retired.path) |named| self.gpa.free(named);
            retired.document.deinit();

            self.dirty = true;
        }

        /// Keeps what a view was showing, against being asked for it again.
        fn park(self: *Self, retired: Retired) !void {
            var leaving = retired;

            const path = leaving.path orelse {
                // A document nobody named cannot be asked for by name.
                leaving.document.deinit();
                return;
            };
            errdefer {
                self.gpa.free(path);
                leaving.document.deinit();
            }

            const slot = try self.parked.getOrPut(self.gpa, path);
            if (slot.found_existing) {
                // Keep what was just put down.
                slot.value_ptr.document.deinit();
                self.gpa.free(path);
            } else {
                slot.key_ptr.* = path;
            }
            slot.value_ptr.* = .{ .document = leaving.document, .position = leaving.position };
        }

        fn redraw(self: *Self) !void {
            // Read rather than listened for: three window events can imply the
            // scale changed, and dragging to another display happens inside the
            // modal loop, where only the watch below runs.
            const scale = displayScale(self.renderer.window);
            if (try self.renderer.atlas.setScale(scale)) self.stack.invalidate();

            // Asked of the columns rather than remembered, so the bar cannot
            // disagree with what is on screen -- a press that moves the keyboard
            // to another column moves the tab in front with it, and nothing had
            // to tell the bar so.
            if (comptime Stack.has(Workspace)) {
                const workspace = self.stack.get(Workspace);
                const views = workspace.get(Views);
                const tabs = workspace.get(Tabs);
                tabs.showing(if (views.focused()) |view| view.path else null);

                // Which files have been changed, asked of the documents that
                // hold them: a document is either in a column or parked, and
                // the bar lists both.
                for (views.items.items) |*view| {
                    if (view.path) |named| tabs.mark(named, view.document.modified);
                }
                var resting = self.parked.iterator();
                while (resting.next()) |entry| {
                    tabs.mark(entry.key_ptr.*, entry.value_ptr.document.modified);
                }
            }

            // The window rather than the swapchain, which is not acquired until
            // `present`. The two can disagree for a frame mid-resize, which is
            // one line too many or too few.
            var width: c_int = 0;
            var height: c_int = 0;
            _ = c.SDL_GetWindowSizeInPixels(self.renderer.window, &width, &height);

            // Everything gets the whole window. A component that divides it --
            // the columns -- does that itself; one that lies over it -- the
            // finder -- wants all of it.
            self.stack.place(.{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(width),
                .height = @floatFromInt(height),
            }, &self.renderer.atlas);

            self.painter.clear();
            try self.stack.draw(&self.renderer.atlas, &self.painter);
            try self.renderer.present(&self.painter);
        }

        /// Windows and macOS run a modal loop while a window is dragged or
        /// resized, and do not hand control back until it ends, so
        /// `SDL_WaitEvent` is stuck inside it and nothing redraws. SDL runs a
        /// watch callback as events are pushed, which happens from within that
        /// loop.
        fn redrawWhileResizing(userdata: ?*anyopaque, event: [*c]c.SDL_Event) callconv(.c) bool {
            if (event.*.type == c.SDL_EVENT_WINDOW_EXPOSED) {
                const app: *Self = @ptrCast(@alignCast(userdata.?));
                // Swallowed: the main loop draws again the moment it gets
                // control back and surfaces the failure there.
                app.redraw() catch {};
            }
            // Watch callbacks cannot filter; the return value is ignored.
            return true;
        }
    };
}

/// Puts a window up and runs `stack` in it until it is closed.
fn run(comptime Stack: type, gpa: std.mem.Allocator, io: std.Io, stack: Stack) !void {
    // macOS makes inertial scroll events of its own and SDL turns them off
    // unless asked. Asking costs nothing while nothing is moving: momentum is
    // more wheel events, and they stop arriving when it stops. Before
    // `SDL_Init`, which is when SDL reads it.
    _ = c.SDL_SetHint(c.SDL_HINT_MAC_SCROLL_MOMENTUM, "1");

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.err("SDL_Init: {s}", .{sdl.lastError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    // The size is in window coordinates. Without `HIGH_PIXEL_DENSITY` the back
    // buffer is that size too and the finished frame is scaled up to the
    // display, which no amount of care in the text pipeline survives.
    const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    const window = c.SDL_CreateWindow("yaz", 1024, 768, flags) orelse {
        std.log.err("SDL_CreateWindow: {s}", .{sdl.lastError()});
        return error.SdlCreateWindow;
    };
    defer c.SDL_DestroyWindow(window);

    std.log.info("video driver: {s}", .{std.mem.span(c.SDL_GetCurrentVideoDriver())});

    // Text arrives as finished characters rather than keys. The platform's
    // input method gets the keystrokes first, so a dead key, a compose
    // sequence or a CJK conversion has already become the character it means
    // by the time it reaches us.
    if (!c.SDL_StartTextInput(window)) {
        std.log.err("SDL_StartTextInput: {s}", .{sdl.lastError()});
        return error.SdlStartTextInput;
    }
    defer _ = c.SDL_StopTextInput(window);

    var app: App(Stack) = .{
        .gpa = gpa,
        .io = io,
        .renderer = try Renderer.init(gpa, window),
        .painter = .init(gpa),
        .stack = stack,
    };
    defer app.deinit();

    // Only a window with a file in it has anything to be called. SDL copies the
    // string, so the sentinel it wants is borrowed for the length of the call
    // rather than carried around by the view -- where it would be a path whose
    // allocation is one byte longer than its length, and the parked documents
    // are keyed by exactly that path.
    if (comptime Stack.has(Workspace)) {
        if (app.stack.get(Workspace).get(Views).items.items[0].path) |named| {
            const title = try gpa.dupeZ(u8, named);
            defer gpa.free(title);
            _ = c.SDL_SetWindowTitle(window, title.ptr);
        }
    }

    if (!c.SDL_AddEventWatch(App(Stack).redrawWhileResizing, &app)) {
        std.log.err("SDL_AddEventWatch: {s}", .{sdl.lastError()});
        return error.SdlAddEventWatch;
    }
    defer c.SDL_RemoveEventWatch(App(Stack).redrawWhileResizing, &app);

    // Blocking wait, not a poll loop: idle costs nothing. Waking up is not a
    // reason to draw, though; only a change to what is on screen is.
    var event: c.SDL_Event = undefined;
    while (app.running) {
        if (app.isDirty()) {
            try app.redraw();
            app.setDirty(false);
        }

        if (!c.SDL_WaitEvent(&event)) {
            std.log.err("SDL_WaitEvent: {s}", .{sdl.lastError()});
            return error.SdlWaitEvent;
        }

        // Everything already queued belongs to the frame this wakeup produces.
        // Folding a burst into one redraw is what stops a keystroke queueing up
        // behind presents of unchanged content: presenting blocks on the
        // swapchain, so each redundant one costs real latency, not just work.
        while (true) {
            const density = c.SDL_GetWindowPixelDensity(window);
            if (Event.init(&event, density)) |what| try app.update(what);
            if (!c.SDL_PollEvent(&event)) break;
        }
    }
}

/// `yaz setup`, and exactly that. A file genuinely named `setup` is still
/// openable, by naming it `./setup`.
fn wantsSetup(init: std.process.Init) !bool {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.skip(); // The program itself.
    const first = args.next() orelse return false;
    if (!std.mem.eql(u8, first, "setup")) return false;
    return args.next() == null;
}

/// Installs the two tools the editor will not run without.
///
/// A command rather than something startup does on its own: this is the only
/// place in yaz that reaches the network, and it should happen because it was
/// asked for.
fn setup(init: std.process.Init) !void {
    var failed = false;

    for (tools.Tool.all) |tool| {
        const exe = try tools.path(init.gpa, init.minimal.environ, tool);
        defer init.gpa.free(exe);

        if (tools.probe(init.gpa, init.io, exe)) {
            std.log.info("{s} is already installed at {s}", .{ tool.title(), exe });
            continue;
        }

        std.log.info("installing {s}", .{tool.title()});
        tools.install(init.gpa, init.io, init.minimal.environ, tool) catch |err| {
            std.log.err("{s}: {s}", .{ tool.title(), @errorName(err) });
            failed = true;
            continue;
        };

        // What was written, not what was downloaded: the whole point of the
        // check is that the thing now on disk runs.
        if (!tools.probe(init.gpa, init.io, exe)) {
            std.log.err("{s}: installed at {s} but it does not run", .{ tool.title(), exe });
            failed = true;
            continue;
        }

        std.log.info("{s} installed at {s}", .{ tool.title(), exe });
    }

    // Exiting rather than returning the error: everything that went wrong has
    // already been reported in terms a person can act on, and returning it would
    // add a Zig stack trace that says nothing they can.
    if (failed) std.process.exit(1);
}

/// Both fields are owned by the caller. `path` is null when nothing was named,
/// which is not the same as a file that turned out to be empty.
const Opened = struct {
    text: []u8,
    /// Sentinel-terminated because it goes to SDL as a window title.
    path: ?[:0]u8,

    fn deinit(self: *Opened, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        if (self.path) |path| gpa.free(path);
    }
};

/// Every file named on the command line, in the order they were named, and one
/// empty document when none was. Never empty, so there is always a view.
fn openAll(init: std.process.Init) !std.ArrayList(Opened) {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip(); // The program itself.

    var opened: std.ArrayList(Opened) = .empty;
    errdefer {
        for (opened.items) |*file| file.deinit(init.gpa);
        opened.deinit(init.gpa);
    }

    // Read one at a time rather than gathering the paths first: the iterator
    // owns what it returns until the next call, and `open` copies it.
    while (args.next()) |named| try opened.append(init.gpa, try open(init.gpa, init.io, named));

    if (opened.items.len == 0) {
        try opened.append(init.gpa, .{ .text = try init.gpa.alloc(u8, 0), .path = null });
    }
    return opened;
}

/// Reads one named file.
///
/// A path that does not exist opens empty under that name, the way a new file
/// starts. Anything else stops the program: an empty window otherwise looks
/// exactly like an empty file.
fn open(gpa: std.mem.Allocator, io: std.Io, named: []const u8) !Opened {
    const path = try gpa.dupeZ(u8, named);
    errdefer gpa.free(path);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(file_limit)) catch |err| switch (err) {
        error.FileNotFound => return .{ .text = try gpa.alloc(u8, 0), .path = path },
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
    errdefer gpa.free(contents);

    if (firstInvalidUtf8(contents)) |offset| {
        std.log.err("{s} is not UTF-8: the byte at offset {d} does not begin or continue a character", .{ path, offset });
        return error.InvalidUtf8;
    }

    return .{ .text = try stripCarriageReturns(gpa, contents), .path = path };
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
fn stripCarriageReturns(gpa: std.mem.Allocator, text: []u8) ![]u8 {
    var found: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte == '\r' and i + 1 < text.len and text[i + 1] == '\n') found += 1;
    }
    if (found == 0) return text;

    const stripped = try gpa.alloc(u8, text.len - found);
    var out: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
        stripped[out] = byte;
        out += 1;
    }
    std.debug.assert(out == stripped.len);

    gpa.free(text);
    return stripped;
}

test "stripCarriageReturns leaves a file that has none alone" {
    const gpa = std.testing.allocator;
    const text = try gpa.dupe(u8, "one\ntwo\n");
    const kept = try stripCarriageReturns(gpa, text);
    defer gpa.free(kept);
    // The same allocation, not a copy of it.
    try std.testing.expectEqual(text.ptr, kept.ptr);
}

test "stripCarriageReturns turns CRLF into LF" {
    const gpa = std.testing.allocator;
    const text = try gpa.dupe(u8, "one\r\ntwo\r\n");
    const stripped = try stripCarriageReturns(gpa, text);
    defer gpa.free(stripped);
    try std.testing.expectEqualStrings("one\ntwo\n", stripped);
}

test "stripCarriageReturns keeps a carriage return that is not a line ending" {
    const gpa = std.testing.allocator;
    // A lone CR is not CRLF and is left where it is; only the pair is a line
    // ending, and a file using bare CR is not a thing this reads.
    const text = try gpa.dupe(u8, "one\rtwo\r\n");
    const stripped = try stripCarriageReturns(gpa, text);
    defer gpa.free(stripped);
    try std.testing.expectEqualStrings("one\rtwo\n", stripped);
}

test "stripCarriageReturns handles a trailing carriage return" {
    const gpa = std.testing.allocator;
    // Last byte, so there is no next one to look at; the bounds check is the
    // whole of what this is here to catch.
    const text = try gpa.dupe(u8, "one\n\r");
    const stripped = try stripCarriageReturns(gpa, text);
    defer gpa.free(stripped);
    try std.testing.expectEqualStrings("one\n\r", stripped);
}

test {
    // A test build analyses only what a test reaches. Without the first line
    // nothing below `main` in this file is compiled at all, which is how a green
    // `zig build test` has twice been followed by a failing `zig build`.
    //
    // The imports are separate from it: reaching a file's functions is not the
    // same as collecting its tests, and tools.zig's had never run.
    _ = &main;
    _ = @import("./tools.zig");
    _ = @import("./renderer.zig");
    _ = @import("./components/text_view.zig");
    _ = @import("./components/ztuple.zig");
    _ = @import("./components/htuple.zig");
    _ = @import("./components/hlist.zig");
    _ = @import("./components/tabs.zig");
    _ = @import("./components/vtuple.zig");
}
