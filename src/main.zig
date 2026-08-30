const std = @import("std");

const Renderer = @import("./renderer.zig").Renderer;
const displayScale = @import("./renderer.zig").displayScale;
const TextView = @import("./text_view.zig").TextView;
const Event = @import("./event.zig").Event;
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
    const opened = try open(init);
    defer init.gpa.free(opened.text);
    defer if (opened.path) |path| init.gpa.free(path);

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

    if (opened.path) |path| _ = c.SDL_SetWindowTitle(window, path.ptr);

    var app: App = .{
        .renderer = try Renderer.init(init.gpa, window),
        .view = try TextView.init(init.gpa, opened.text),
    };
    defer app.renderer.deinit();
    defer app.view.deinit();

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
            if (Event.init(&event, density)) |what| try app.handle(what);
            if (!c.SDL_PollEvent(&event)) break;
        }
    }
}

/// Together because the event watch reaches them from behind one `void *`.
const App = struct {
    renderer: Renderer,
    view: TextView,
    running: bool = true,

    /// What has changed at this level, as against inside the view. True to
    /// begin with: the first frame has never been drawn.
    dirty: bool = true,

    /// Answers for everything it holds, so the loop asks one thing.
    fn isDirty(self: *const App) bool {
        return self.dirty or self.view.isDirty();
    }

    fn setDirty(self: *App, value: bool) void {
        self.dirty = value;
        self.view.setDirty(value);
    }

    /// Takes what belongs to the window and hands the rest down. What changed
    /// is not answered here; it is asked for afterwards, through `isDirty`.
    fn handle(self: *App, event: Event) !void {
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

        try self.view.handle(event, &self.renderer.atlas);
    }

    fn redraw(self: *App) !void {
        // Read rather than listened for: three window events can imply the
        // scale changed, and dragging to another display happens inside the
        // modal loop, where only the watch below runs.
        const scale = displayScale(self.renderer.window);
        if (try self.renderer.atlas.setScale(scale)) self.view.invalidate();

        // The window rather than the swapchain, which is not acquired until
        // `present`. The two can disagree for a frame mid-resize, which is one
        // line too many or too few.
        var width: c_int = 0;
        var height: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.renderer.window, &width, &height);

        // The whole window, for now. Whatever else gets drawn will be given a
        // rect of its own out of the same division.
        self.view.place(.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        });

        if (self.view.follow_caret) self.view.scrollToCaret(&self.renderer.atlas);
        const frame = try self.view.layout(&self.renderer.atlas);
        try self.renderer.present(frame.quads, frame.caret, frame.bar);
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
};

/// Reads the file named by the first argument, if there is one.
///
/// A path that does not exist opens empty under that name, the way a new file
/// starts. Anything else stops the program: an empty window otherwise looks
/// exactly like an empty file.
fn open(init: std.process.Init) !Opened {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.skip(); // The program itself.
    const named = args.next() orelse return .{ .text = try init.gpa.alloc(u8, 0), .path = null };

    // The iterator owns what it returns and is about to go.
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
