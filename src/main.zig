const std = @import("std");

const Renderer = @import("./renderer.zig").Renderer;
const c = @import("./renderer.zig").c;
const sdlError = @import("./renderer.zig").sdlError;

pub fn main(init: std.process.Init) !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.err("SDL_Init: {s}", .{sdlError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("yaz", 1024, 768, c.SDL_WINDOW_RESIZABLE) orelse {
        std.log.err("SDL_CreateWindow: {s}", .{sdlError()});
        return error.SdlCreateWindow;
    };
    defer c.SDL_DestroyWindow(window);

    std.log.info("video driver: {s}", .{std.mem.span(c.SDL_GetCurrentVideoDriver())});

    var renderer = try Renderer.init(init.gpa, window);
    defer renderer.deinit();

    if (!c.SDL_AddEventWatch(redrawWhileResizing, &renderer)) {
        std.log.err("SDL_AddEventWatch: {s}", .{sdlError()});
        return error.SdlAddEventWatch;
    }
    defer c.SDL_RemoveEventWatch(redrawWhileResizing, &renderer);

    // Blocking wait, not a poll loop: idle costs nothing. Waking up is not a
    // reason to draw, though; only a change to what is on screen is.
    var dirty = true;
    var running = true;
    var event: c.SDL_Event = undefined;
    while (running) {
        if (dirty) {
            try renderer.present(&sample_text);
            dirty = false;
        }

        if (!c.SDL_WaitEvent(&event)) {
            std.log.err("SDL_WaitEvent: {s}", .{sdlError()});
            return error.SdlWaitEvent;
        }

        // Everything already queued belongs to the frame this wakeup produces.
        // Folding a burst into one redraw is what stops a keystroke queueing up
        // behind presents of unchanged content: presenting blocks on the
        // swapchain, so each redundant one costs real latency, not just work.
        while (true) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                // Nothing else changes the picture yet. Typing will.
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => dirty = true,
                // Exposure belongs to the watcher, which has already drawn by
                // the time the event arrives here; marking it would draw twice.
                else => {},
            }
            if (!c.SDL_PollEvent(&event)) break;
        }
    }
}

/// Windows and macOS run a modal loop of their own while a window is being
/// dragged or resized, and it does not hand control back until the drag ends.
/// `SDL_WaitEvent` is stuck inside it, so nothing redraws, and the area the
/// window has just grown into keeps whatever the new swapchain came with.
///
/// A watch callback is the way out: SDL runs it as events are pushed, which
/// happens from inside that modal loop.
fn redrawWhileResizing(userdata: ?*anyopaque, event: [*c]c.SDL_Event) callconv(.c) bool {
    if (event.*.type == c.SDL_EVENT_WINDOW_EXPOSED) {
        const renderer: *Renderer = @ptrCast(@alignCast(userdata.?));
        // Swallowed rather than reported: the main loop draws again the moment
        // it gets control back, and surfaces the failure there.
        renderer.present(&sample_text) catch {};
    }
    // Watch callbacks cannot filter; the return value is ignored.
    return true;
}

/// Enough text to show that advances differ per character, that the pen lands
/// off the pixel grid as a result, and that shaping produces glyphs no character
/// maps to. Replaced by a real buffer at step 10.
const sample_text = [_][]const u8{
    "The quick brown fox jumps over the lazy dog.",
    "Waltz, bad nymph, for quick jigs vex. 0123456789",
    // fi, ffi and fl are each one glyph here, and no character maps to any of
    // them: they exist only because shaping substituted them in.
    "office difficult flag fluffy affix",
    // The second of these is an e followed by a combining acute, which shaping
    // composes into the same single glyph as the first.
    "caf\u{e9} and cafe\u{301} \u{2014} composed and precomposed",
    "iiiii mmmmm WWWWW ..... proportional, not monospace",
};

test {
    // `main` is never called in a test build, so nothing references the
    // renderer and its tests would be compiled out of the binary entirely.
    _ = @import("./renderer.zig");
}
