const std = @import("std");

const Renderer = @import("./renderer.zig").Renderer;
const TextView = @import("./text_view.zig").TextView;
const sdl = @import("./sdl.zig");
const c = sdl.c;

/// Where the first line's top-left corner sits. Whole pixels, which the layout
/// cache depends on; a margin is not a thing to scroll by fractions of one.
const text_origin: [2]f32 = .{ 48, 48 };

pub fn main(init: std.process.Init) !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.err("SDL_Init: {s}", .{sdl.lastError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("yaz", 1024, 768, c.SDL_WINDOW_RESIZABLE) orelse {
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

    var app: App = .{
        .renderer = try Renderer.init(init.gpa, window),
        .view = try TextView.init(init.gpa, sample_text),
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
        const sprites = try self.view.layout(&self.renderer.atlas, text_origin[0], text_origin[1]);
        try self.renderer.present(sprites);
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

/// Enough text to show that advances differ per character, that the pen lands
/// off the pixel grid as a result, and that shaping produces glyphs no character
/// maps to. Replaced by a file to open once there is one.
const sample_text =
    "The quick brown fox jumps over the lazy dog.\n" ++
    "Waltz, bad nymph, for quick jigs vex. 0123456789\n" ++
    // fi, ffi and fl are each one glyph here, and no character maps to any of
    // them: they exist only because shaping substituted them in.
    "office difficult flag fluffy affix\n" ++
    // The second of these is an e followed by a combining acute, which shaping
    // composes into the same single glyph as the first.
    "caf\u{e9} and cafe\u{301} \u{2014} composed and precomposed\n" ++
    // Neither script is in DejaVu Sans, so these come back as .notdef.
    "\u{6f22}\u{5b57} \u{e17}\u{e35} \u{2014} not in this font\n" ++
    "iiiii mmmmm WWWWW ..... proportional, not monospace";

test {
    // `main` is never called in a test build, so nothing references these and
    // their tests would be compiled out of the binary entirely.
    _ = @import("./renderer.zig");
    _ = @import("./text_view.zig");
}
