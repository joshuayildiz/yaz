const std = @import("std");

const Renderer = @import("./renderer.zig").Renderer;
const displayScale = @import("./renderer.zig").displayScale;
const TextView = @import("./text_view.zig").TextView;
const Event = @import("./event.zig").Event;
const Painter = @import("./painter.zig").Painter;
const Rect = @import("./painter.zig").Rect;
const sdl = @import("./sdl.zig");
const c = sdl.c;

/// The largest file yaz will open. What still costs per line of the document
/// rather than per line on screen is the layout cache, which holds a 64-byte
/// entry for each of them, and the line index behind it.
const file_limit = 1 << 20;

pub fn main(init: std.process.Init) !void {
    // macOS makes inertial scroll events of its own and SDL turns them off
    // unless asked. Asking costs nothing while nothing is moving: momentum is
    // more wheel events, and they stop arriving when it stops. Before
    // `SDL_Init`, which is when SDL reads it.
    _ = c.SDL_SetHint(c.SDL_HINT_MAC_SCROLL_MOMENTUM, "1");

    // Before SDL, so a file that cannot be opened fails without a window having
    // appeared and gone again.
    var opened = try openAll(init);
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

    if (opened.items[0].path) |path| _ = c.SDL_SetWindowTitle(window, path.ptr);

    var app: App = .{
        .gpa = init.gpa,
        .renderer = try Renderer.init(init.gpa, window),
        .painter = .init(init.gpa),
    };
    defer app.deinit();

    try app.views.ensureTotalCapacity(init.gpa, opened.items.len);
    for (opened.items) |file| app.views.appendAssumeCapacity(try TextView.init(init.gpa, file.text));

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

/// Together because the event watch reaches them from behind one `void *`.
const App = struct {
    gpa: std.mem.Allocator,
    renderer: Renderer,

    /// Left to right across the window, and never empty: a document nobody
    /// named is still a document.
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
        for (self.views.items) |*view| view.deinit();
        self.views.deinit(self.gpa);
        self.painter.deinit();
        self.renderer.deinit();
    }

    /// Answers for everything it holds, so the loop asks one thing.
    fn isDirty(self: *const App) bool {
        for (self.views.items) |*view| {
            if (view.isDirty()) return true;
        }
        return self.dirty;
    }

    fn setDirty(self: *App, value: bool) void {
        self.dirty = value;
        for (self.views.items) |*view| view.setDirty(value);
    }

    /// Divides the room it has been given between what it holds: equal columns,
    /// left to right.
    fn place(self: *App, rect: Rect) void {
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
        for (self.views.items) |*view| try view.draw(&self.renderer.atlas, painter);
    }

    fn redraw(self: *App) !void {
        // Read rather than listened for: three window events can imply the
        // scale changed, and dragging to another display happens inside the
        // modal loop, where only the watch below runs.
        const scale = displayScale(self.renderer.window);
        if (try self.renderer.atlas.setScale(scale)) {
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
    while (args.next()) |named| try opened.append(init.gpa, try open(init, named));

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
fn open(init: std.process.Init, named: []const u8) !Opened {
    const path = try init.gpa.dupeZ(u8, named);
    errdefer init.gpa.free(path);

    const contents = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(file_limit)) catch |err| switch (err) {
        error.FileNotFound => return .{ .text = try init.gpa.alloc(u8, 0), .path = path },
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
    errdefer init.gpa.free(contents);

    if (firstInvalidUtf8(contents)) |offset| {
        std.log.err("{s} is not UTF-8: the byte at offset {d} does not begin or continue a character", .{ path, offset });
        return error.InvalidUtf8;
    }

    return .{ .text = try stripCarriageReturns(init.gpa, contents), .path = path };
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
    _ = @import("./text_view.zig");
}
