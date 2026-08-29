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

    // Blocking wait, not a poll loop: idle costs nothing.
    var event: c.SDL_Event = undefined;
    while (true) {
        try renderer.present(&sample_text);
        if (!c.SDL_WaitEvent(&event)) {
            std.log.err("SDL_WaitEvent: {s}", .{sdlError()});
            return error.SdlWaitEvent;
        }
        if (event.type == c.SDL_EVENT_QUIT) break;
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

/// Enough text to show that advances differ per character and that the pen
/// lands off the pixel grid as a result. Replaced by a real buffer at step 10.
const sample_text = [_][]const u8{
    "The quick brown fox jumps over the lazy dog.",
    "Waltz, bad nymph, for quick jigs vex. 0123456789",
    "iiiii mmmmm WWWWW ..... proportional, not monospace",
};

test {
    // `main` is never called in a test build, so nothing references the
    // renderer and its tests would be compiled out of the binary entirely.
    _ = @import("./renderer.zig");
}
