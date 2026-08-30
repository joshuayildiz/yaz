//! What happened, in the program's own words rather than SDL's.

const std = @import("std");

const c = @import("./sdl.zig").c;

/// Already in pixels by the time one of these is made, so nothing that handles
/// one has to know what a display scale is, and nothing that handles one has to
/// know what SDL calls things.
pub const Event = union(enum) {
    quit,
    resized,

    text: []const u8,
    newline,
    backspace,

    /// Pixels to move a view by, positive downwards, and where the pointer was
    /// while it happened -- which is what decides whose view moves.
    wheel: struct { delta: f32, at: [2]f32 },
    press: [2]f32,
    move: [2]f32,
    release,

    /// Null for what nothing here acts on, which is most of what SDL sends.
    ///
    /// `density` is how many pixels a window coordinate is worth. Applying it
    /// here is what lets everything downstream speak in one unit.
    pub fn init(event: *const c.SDL_Event, density: f32) ?Event {
        return switch (event.type) {
            c.SDL_EVENT_QUIT => .quit,
            c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => .resized,

            // Text arrives as finished characters rather than keys; return and
            // backspace are not text and do not arrive as any.
            c.SDL_EVENT_TEXT_INPUT => .{ .text = std.mem.span(event.text.text) },
            c.SDL_EVENT_KEY_DOWN => switch (event.key.key) {
                c.SDLK_RETURN => .newline,
                c.SDLK_BACKSPACE => .backspace,
                else => null,
            },

            // A precise device is reported in tenths of a point, so ten times
            // the delta is how far a finger moved. A notched wheel reports whole
            // lines instead and nothing tells the two apart -- macOS registers
            // one mouse and gives it no name -- so everything is read as points.
            // Negated because SDL counts a wheel positive away from the reader,
            // which is towards the start of the document.
            c.SDL_EVENT_MOUSE_WHEEL => .{ .wheel = .{
                .delta = -event.wheel.y * 10 * density,
                .at = .{ event.wheel.mouse_x * density, event.wheel.mouse_y * density },
            } },

            c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (event.button.button == c.SDL_BUTTON_LEFT)
                .{ .press = .{ event.button.x * density, event.button.y * density } }
            else
                null,
            c.SDL_EVENT_MOUSE_MOTION => .{ .move = .{ event.motion.x * density, event.motion.y * density } },
            c.SDL_EVENT_MOUSE_BUTTON_UP => if (event.button.button == c.SDL_BUTTON_LEFT)
                .release
            else
                null,

            // Exposure belongs to the resize watch, which has already drawn by
            // the time the event arrives here; acting on it would draw twice.
            else => null,
        };
    }
};
