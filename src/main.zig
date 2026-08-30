const std = @import("std");

const Renderer = @import("./renderer.zig").Renderer;
const displayScale = @import("./renderer.zig").displayScale;
const TextView = @import("./text_view.zig").TextView;
const sdl = @import("./sdl.zig");
const c = sdl.c;

/// The largest file yaz will open.
///
/// Not a limit on the buffer or on what can be edited: `TextView.layout` places
/// every glyph of every line on every frame, so a large file is slow in a way
/// that has nothing to do with reading it, and the atlas runs out of room before
/// the machine runs out of memory. Refusing with a number is better than opening
/// something that appears to hang. It comes out when layout draws only what is
/// on screen.
const file_limit = 1 << 20;

/// Where the first line's top-left corner sits, at a display scale of one.
/// Scaled with the text, so the margin is the same size to look at whatever the
/// display, rather than half of one on a dense display and twice on a coarse.
const text_margin: [2]f32 = .{ 48, 48 };

/// The margin in device pixels. Whole ones, which the layout cache depends on:
/// a fractional origin would change which subpixel variant every cached glyph
/// points at. A margin is not a thing to scroll by fractions of a pixel.
fn textOrigin(scale: f32) [2]f32 {
    return .{ @round(text_margin[0] * scale), @round(text_margin[1] * scale) };
}

pub fn main(init: std.process.Init) !void {
    // Before SDL, so that a file yaz cannot open fails without a window having
    // appeared and gone again.
    const opened = try open(init);
    defer init.gpa.free(opened.text);
    defer if (opened.path) |path| init.gpa.free(path);

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.err("SDL_Init: {s}", .{sdl.lastError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    // The size is in window coordinates, which are not pixels on every display.
    // Without `HIGH_PIXEL_DENSITY` the platform hands back a back buffer at the
    // window's size in those coordinates and scales the finished frame up to the
    // display, which is a blur no amount of care in the text pipeline survives.
    // With it, the swapchain is the display's own pixels and every glyph is
    // rasterised for the grid it lands on.
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

    // The path as it was typed, which is what the person who typed it will
    // recognise; a file with no name is still yaz.
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
    var dirty = true;
    var running = true;
    var event: c.SDL_Event = undefined;
    while (running) {
        if (dirty) {
            try app.redraw();
            dirty = false;
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
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => dirty = true,
                c.SDL_EVENT_TEXT_INPUT => {
                    try app.view.insert(std.mem.span(event.text.text));
                    dirty = true;
                },
                // Return and backspace are not text and do not arrive as any.
                c.SDL_EVENT_KEY_DOWN => switch (event.key.key) {
                    c.SDLK_RETURN => {
                        try app.view.insert("\n");
                        dirty = true;
                    },
                    c.SDLK_BACKSPACE => {
                        if (try app.view.backspace()) dirty = true;
                    },
                    else => {},
                },
                // Where the caret goes is a question about the layout, so the
                // view answers it; nothing here knows how wide a character is.
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        // One of the two places a window coordinate gets in.
                        // Everything past here is in pixels, so it is converted
                        // at the door rather than carried further. Density, not
                        // display scale: this is asking how many pixels a point
                        // is, not how large to draw.
                        const density = c.SDL_GetWindowPixelDensity(window);
                        const origin = textOrigin(app.renderer.atlas.scale);
                        try app.view.moveCaretTo(
                            &app.renderer.atlas,
                            origin[0],
                            origin[1],
                            .{ event.button.x * density, event.button.y * density },
                        );
                        dirty = true;
                    }
                },
                // Exposure belongs to the watcher, which has already drawn by
                // the time the event arrives here; marking it would draw twice.
                else => {},
            }
            if (!c.SDL_PollEvent(&event)) break;
        }
    }
}

/// A view of the document and the thing that draws it, together because the
/// event watch needs them from behind one `void *`.
const App = struct {
    renderer: Renderer,
    view: TextView,

    fn redraw(self: *App) !void {
        // Read rather than listened for. Three window events can imply the scale
        // has changed, and one of the ways it changes -- dragging the window to
        // another display -- runs inside the platform's modal loop, where the
        // event watch below is the only thing that gets called at all. Comparing
        // the value cannot miss any of that, and it costs a load on a path that
        // only runs because something changed anyway.
        const scale = displayScale(self.renderer.window);
        if (try self.renderer.atlas.setScale(scale)) self.view.invalidate();

        const origin = textOrigin(scale);
        const frame = try self.view.layout(&self.renderer.atlas, origin[0], origin[1]);
        try self.renderer.present(frame.quads, frame.caret);
    }
};

/// Windows and macOS run a modal loop of their own while a window is being
/// dragged or resized, and it does not hand control back until the drag ends.
/// `SDL_WaitEvent` is stuck inside it, so nothing redraws, and the area the
/// window has just grown into keeps whatever the new swapchain came with.
///
/// A watch callback is the way out: SDL runs it as events are pushed, which
/// happens from inside that modal loop.
fn redrawWhileResizing(userdata: ?*anyopaque, event: [*c]c.SDL_Event) callconv(.c) bool {
    if (event.*.type == c.SDL_EVENT_WINDOW_EXPOSED) {
        const app: *App = @ptrCast(@alignCast(userdata.?));
        // Swallowed rather than reported: the main loop draws again the moment
        // it gets control back, and surfaces the failure there.
        app.redraw() catch {};
    }
    // Watch callbacks cannot filter; the return value is ignored.
    return true;
}

/// What a run of yaz starts with.
const Opened = struct {
    /// Owned by the caller. Empty both for a file that does not exist yet and
    /// for no file at all.
    text: []u8,

    /// Owned by the caller, and null when nothing was named -- which is not the
    /// same as a file that turned out to be empty. Sentinel-terminated because
    /// it goes to SDL as a window title.
    path: ?[:0]u8,
};

/// Reads the file named by the first argument, if there is one.
///
/// A path that does not exist is not a failure: it opens empty under that name,
/// the way a new file starts. Anything else -- a directory, a permission, a file
/// past `file_limit` -- is reported and stops the program, because the
/// alternative is an editor showing an empty document for a file that is not
/// empty, and no way to tell the two apart.
fn open(init: std.process.Init) !Opened {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    // The first argument is the program itself.
    _ = args.skip();
    const named = args.next() orelse return .{ .text = try init.gpa.alloc(u8, 0), .path = null };

    // Copied because the iterator owns what it returns and is about to go.
    const path = try init.gpa.dupeZ(u8, named);
    errdefer init.gpa.free(path);

    const contents = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(file_limit)) catch |err| switch (err) {
        // Naming a file that is not there is how a new one begins, so this is
        // an empty document rather than a refusal.
        error.FileNotFound => return .{ .text = try init.gpa.alloc(u8, 0), .path = path },
        error.StreamTooLong => {
            std.log.err(
                "{s} is larger than the {d}MB yaz will open, because layout draws every line rather than the ones on screen",
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

/// Where the first byte that is not part of a well-formed UTF-8 sequence is, or
/// null if there is no such byte.
///
/// An offset rather than a yes or no: "this is not UTF-8" is not something the
/// person who typed the path can do anything with, and "byte 4102 is not" is.
///
/// Worth refusing over rather than drawing something. Every layer above assumes
/// UTF-8 -- the shaper is handed the bytes as UTF-8, and stepping the caret back
/// over a character walks continuation bytes until it finds one that is not.
/// HarfBuzz would substitute a replacement character and carry on, so the text
/// would merely look wrong; backspace would not. It would step back over as many
/// stray continuation bytes as happened to be adjacent and delete all of them,
/// which is an editor quietly making a file worse than it found it.
fn firstInvalidUtf8(text: []const u8) ?usize {
    // One walk rather than `utf8ValidateSlice` first and this only on failure.
    // That would be faster on a large valid file and would mean two pieces of
    // code deciding what UTF-8 is, which is one more than there should be: the
    // day they disagreed, the fast path would say no and this would find
    // nothing to point at. `utf8Decode` refuses overlong encodings, surrogate
    // halves and codepoints past U+10FFFF, so the walk is the whole rule.
    var at: usize = 0;
    while (at < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[at]) catch return at;
        // A sequence that runs off the end is truncated, and the offset to
        // report is where it started rather than where the file stopped.
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

/// Turns CRLF into LF. Frees what it is given if it has to replace it, and hands
/// it straight back when there is nothing to do, which is every file not written
/// on Windows.
///
/// A carriage return is not a line break to the line index, so it would stay on
/// the end of every line and reach the shaper, which would set it as .notdef --
/// a box at the end of every line of a perfectly ordinary file. Stripping on the
/// way in also leaves one kind of line ending for everything downstream to
/// assume rather than two.
///
/// The bytes then stop matching the file exactly. That is a trade to revisit
/// when there is a way to save and not before: nothing can be written back yet,
/// so nothing can be written back wrongly.
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
