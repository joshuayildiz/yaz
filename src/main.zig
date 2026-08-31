const std = @import("std");

const Renderer = @import("./renderer.zig").Renderer;
const displayScale = @import("./renderer.zig").displayScale;
const TextView = @import("./components/text_view.zig").TextView;
const Position = @import("./components/text_view.zig").Position;
const Retired = @import("./components/text_view.zig").Retired;
const Document = @import("./document.zig").Document;
const Event = @import("./event.zig").Event;
const Painter = @import("./painter.zig").Painter;
const Rect = @import("./painter.zig").Rect;
const sdl = @import("./sdl.zig");
const tools = @import("./tools.zig");
const Healthcheck = @import("./components/healthcheck.zig").Healthcheck;
const Finder = @import("./components/finder.zig").Finder;
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

    // macOS makes inertial scroll events of its own and SDL turns them off
    // unless asked. Asking costs nothing while nothing is moving: momentum is
    // more wheel events, and they stop arriving when it stops. Before
    // `SDL_Init`, which is when SDL reads it.
    _ = c.SDL_SetHint(c.SDL_HINT_MAC_SCROLL_MOMENTUM, "1");

    // The tools before the files: when either is missing nothing but the
    // healthcheck runs, and reading a file first would report the wrong problem
    // when the path is also bad.
    const absent = try tools.missing(init.gpa, init.io, init.minimal.environ);

    // Before SDL, so a file that cannot be opened fails without a window having
    // appeared and gone again.
    var opened: std.ArrayList(Opened) = if (absent.any()) .empty else try openAll(init);
    defer {
        for (opened.items) |*file| file.deinit(init.gpa);
        opened.deinit(init.gpa);
    }

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

    if (opened.items.len > 0) {
        if (opened.items[0].path) |path| _ = c.SDL_SetWindowTitle(window, path.ptr);
    }

    var app: App = .{
        .gpa = init.gpa,
        .io = init.io,
        .health = if (absent.any())
            try Healthcheck.init(init.gpa, init.minimal.environ, absent)
        else
            null,
        .renderer = try Renderer.init(init.gpa, window),
        .painter = .init(init.gpa),
        // Only where there is an editor to find files for. With a tool missing
        // its paths cannot even be resolved.
        .finder = if (absent.any()) null else try Finder.init(init.gpa, init.io, init.minimal.environ),
    };
    defer app.deinit();

    try app.views.ensureTotalCapacity(init.gpa, opened.items.len);
    for (opened.items) |file| {
        app.views.appendAssumeCapacity(try TextView.init(init.gpa, file.text, file.path));
    }

    if (!c.SDL_AddEventWatch(redrawWhileResizing, &app)) {
        std.log.err("SDL_AddEventWatch: {s}", .{sdl.lastError()});
        return error.SdlAddEventWatch;
    }
    defer c.SDL_RemoveEventWatch(redrawWhileResizing, &app);

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

/// Where the pointer was, for the events that carry it.
fn pointer(event: Event) ?[2]f32 {
    return switch (event) {
        .press, .move => |at| at,
        .wheel => |wheel| wheel.at,
        else => null,
    };
}

/// A file that is in memory but not on screen.
const Parked = struct {
    document: Document,
    position: Position,
};

/// Together because the event watch reaches them from behind one `void *`.
const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    renderer: Renderer,

    /// When set, one of the two tools does not run, and this is the whole
    /// window: no views, no files read, nothing routed anywhere else.
    health: ?Healthcheck = null,

    /// Null only alongside `health`, for the same reason.
    finder: ?Finder = null,

    /// Files that have been looked at and are not on screen now, by path.
    ///
    /// Kept whole rather than re-read: a document is a buffer, a line index and
    /// every line already shaped, and looking away from a file is no reason to
    /// throw that away and pay for it again on the way back. Keys are owned, and
    /// a document is either here or in exactly one view, never both.
    parked: std.StringHashMapUnmanaged(Parked) = .empty,

    /// Left to right across the window. Empty only while `health` is set; a
    /// document nobody named is still a document.
    views: std.ArrayList(TextView) = .empty,

    /// Which of them a keystroke goes to. Moved by a press and by nothing else:
    /// the pointer routes by position without consulting it, so the wheel turns
    /// whatever it is over without deciding where typing lands.
    focus: usize = 0,

    painter: Painter,
    running: bool = true,

    /// What has changed at this level, as against inside the view. True to
    /// begin with: the first frame has never been drawn.
    dirty: bool = true,

    fn deinit(self: *App) void {
        var resting = self.parked.iterator();
        while (resting.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            entry.value_ptr.document.deinit();
        }
        self.parked.deinit(self.gpa);

        if (self.finder) |*finder| finder.deinit();
        if (self.health) |*health| health.deinit();
        for (self.views.items) |*view| view.deinit();
        self.views.deinit(self.gpa);
        self.painter.deinit();
        self.renderer.deinit();
    }

    /// Answers for everything it holds, so the loop asks one thing.
    fn isDirty(self: *const App) bool {
        if (self.health) |*health| return self.dirty or health.isDirty();
        if (self.finder) |*finder| {
            if (finder.isDirty()) return true;
        }
        for (self.views.items) |*view| {
            if (view.isDirty()) return true;
        }
        return self.dirty;
    }

    fn setDirty(self: *App, value: bool) void {
        self.dirty = value;
        if (self.health) |*health| return health.setDirty(value);
        if (self.finder) |*finder| finder.setDirty(value);
        for (self.views.items) |*view| view.setDirty(value);
    }

    /// Divides the room it has been given between what it holds: equal columns,
    /// left to right.
    fn place(self: *App, rect: Rect) void {
        if (self.health) |*health| return health.place(rect);

        // The whole window: it is an overlay, not one of the columns.
        if (self.finder) |*finder| finder.place(rect);

        const count: f32 = @floatFromInt(self.views.items.len);
        var left = rect.x;
        for (self.views.items, 1..) |*view, nth| {
            // Each edge from the full width rather than by adding widths up, so
            // rounding cannot leave a seam between two columns or short of the
            // last one.
            const right = @round(rect.x + rect.width * @as(f32, @floatFromInt(nth)) / count);
            view.place(.{ .x = left, .y = rect.y, .width = right - left, .height = rect.height });
            left = right;
        }
    }

    /// Takes what belongs to the window and hands the rest down. What changed
    /// is not answered here; it is asked for afterwards, through `isDirty`.
    fn update(self: *App, event: Event) !void {
        switch (event) {
            .quit => {
                self.running = false;
                return;
            },
            .resized => {
                self.dirty = true;
                return;
            },
            else => {},
        }

        // Nothing below the window works while a tool is missing.
        if (self.health) |*health| return health.update(event);

        if (self.finder) |*finder| {
            if (event == .find and !finder.isOpen()) return finder.show();

            // While it is up it has the keyboard entirely, and the pointer is
            // not routed to it at all -- clicking a view behind it would be a
            // way to type into something the panel is covering.
            if (finder.isOpen()) {
                if (try finder.update(event)) |path| {
                    defer self.gpa.free(path);
                    try self.reveal(path);
                }
                return;
            }
        }

        const atlas = &self.renderer.atlas;

        // A view holding the scrollbar keeps the pointer until it lets go,
        // wherever it wanders. Without this a drag crossing into the next view
        // would be handed over half way through.
        if (self.holding()) |held| return self.views.items[held].update(event, atlas);

        // Otherwise a pointer goes to whatever it is over, focus or no focus:
        // the wheel turns the view under it, which is what one expects of it.
        if (pointer(event)) |at| {
            const which = self.over(at) orelse return;

            // A press, and only a press. A wheel or a pointer merely passing
            // over would move where typing lands without anyone asking it to.
            //
            // Nothing is marked dirty for the move itself: focus is not drawn,
            // so a frame showing it would be a frame identical to the last, and
            // presenting one costs the wait for a swapchain image.
            if (event == .press) self.focus = which;

            return self.views.items[which].update(event, atlas);
        }

        // Everything left is typing, which goes to the focused view wherever
        // the pointer happens to be.
        try self.views.items[self.focus].update(event, atlas);
    }

    /// Which view has hold of the pointer through its scrollbar, if any.
    fn holding(self: *App) ?usize {
        for (self.views.items, 0..) |*view, which| {
            if (view.drag != null) return which;
        }
        return null;
    }

    /// Which view a point falls in. The columns do not overlap, so at most one
    /// can answer.
    fn over(self: *App, at: [2]f32) ?usize {
        for (self.views.items, 0..) |*view, which| {
            if (view.rect.contains(at)) return which;
        }
        return null;
    }

    /// Every quad the frame is made of, from everything it holds.
    fn draw(self: *App, painter: *Painter) !void {
        if (self.health) |*health| return health.draw(&self.renderer.atlas, painter);
        for (self.views.items) |*view| try view.draw(&self.renderer.atlas, painter);
        if (self.finder) |*finder| try finder.draw(&self.renderer.atlas, painter);
    }

    /// Puts `path` in front of the reader.
    ///
    /// A view already showing it is focused rather than a second copy opened,
    /// which is both what one expects and the only way two views of one file
    /// cannot drift apart -- they share no document.
    fn reveal(self: *App, path: []const u8) !void {
        for (self.views.items, 0..) |*view, which| {
            const named = view.path orelse continue;
            if (!std.mem.eql(u8, named, path)) continue;

            self.focus = which;
            return;
        }

        var document: Document = undefined;
        var was: ?Position = null;

        if (self.parked.fetchRemove(path)) |entry| {
            // Looked at before: everything about it is still here.
            self.gpa.free(entry.key);
            document = entry.value.document;
            was = entry.value.position;
        } else {
            // Through `open`, so a file picked here meets the same rules as one
            // named on the command line: the size limit, the UTF-8 check, and
            // CRLF turned into LF.
            var file = try open(self.gpa, self.io, path);
            defer file.deinit(self.gpa);
            document = try Document.init(self.gpa, file.text);
        }
        errdefer document.deinit();

        const retired = try self.views.items[self.focus].swap(
            document,
            path,
            was,
            &self.renderer.atlas,
        );
        try self.park(retired);
    }

    /// Keeps what a view was showing, against being asked for it again.
    fn park(self: *App, retired: Retired) !void {
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
            // The same file was open in two views, which only the command line
            // can arrange. Keep what was just put down.
            slot.value_ptr.document.deinit();
            self.gpa.free(path);
        } else {
            slot.key_ptr.* = path;
        }
        slot.value_ptr.* = .{ .document = leaving.document, .position = leaving.position };
    }

    fn redraw(self: *App) !void {
        // Read rather than listened for: three window events can imply the
        // scale changed, and dragging to another display happens inside the
        // modal loop, where only the watch below runs.
        const scale = displayScale(self.renderer.window);
        if (try self.renderer.atlas.setScale(scale)) {
            if (self.health) |*health| health.invalidate();
            if (self.finder) |*finder| finder.invalidate();
            for (self.views.items) |*view| view.invalidate();
        }

        // The window rather than the swapchain, which is not acquired until
        // `present`. The two can disagree for a frame mid-resize, which is one
        // line too many or too few.
        var width: c_int = 0;
        var height: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.renderer.window, &width, &height);

        self.place(.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        });

        for (self.views.items) |*view| {
            if (view.follow_caret) view.scrollToCaret(&self.renderer.atlas);
        }

        self.painter.clear();
        try self.draw(&self.painter);
        try self.renderer.present(&self.painter);
    }
};

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

/// Windows and macOS run a modal loop while a window is dragged or resized, and
/// do not hand control back until it ends, so `SDL_WaitEvent` is stuck inside it
/// and nothing redraws. SDL runs a watch callback as events are pushed, which
/// happens from within that loop.
fn redrawWhileResizing(userdata: ?*anyopaque, event: [*c]c.SDL_Event) callconv(.c) bool {
    if (event.*.type == c.SDL_EVENT_WINDOW_EXPOSED) {
        const app: *App = @ptrCast(@alignCast(userdata.?));
        // Swallowed: the main loop draws again the moment it gets control back
        // and surfaces the failure there.
        app.redraw() catch {};
    }
    // Watch callbacks cannot filter; the return value is ignored.
    return true;
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
    // `main` is never called in a test build, so nothing references these and
    // their tests would be compiled out of the binary entirely.
    _ = @import("./renderer.zig");
    _ = @import("./components/text_view.zig");
}
