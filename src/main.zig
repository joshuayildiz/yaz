const std = @import("std");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

/// SDL reports failures out of band; this is only meaningful right after one.
fn sdlError() []const u8 {
    return std.mem.span(c.SDL_GetError());
}

pub fn main(init: std.process.Init) !void {
    _ = init;

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

    // Blocking wait, not a poll loop: idle costs nothing.
    var event: c.SDL_Event = undefined;
    while (c.SDL_WaitEvent(&event)) {
        if (event.type == c.SDL_EVENT_QUIT) break;
    }
}
