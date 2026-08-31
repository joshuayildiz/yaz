//! What happened, in the program's own words rather than SDL's.

const std = @import("std");

const c = @import("./sdl.zig").c;

/// What a component wants done that it cannot do itself, answered to whatever
/// is holding it -- the only thing that knows what else there is.
pub const Intent = union(enum) {
    /// Dealt with, or not mine. Nothing for anyone above to do.
    nothing,
    /// I am done being in front. Put me back where I was.
    dismiss,
    /// Put this file in front of the reader, in whichever column has the
    /// keyboard. Whoever takes it owns the path.
    open: []u8,
    /// Show this file and nothing else. Whoever takes it owns the path.
    only: []u8,
};

/// Already in pixels by the time one of these is made, so nothing that handles
/// one has to know what a display scale is, and nothing that handles one has to
/// know what SDL calls things.
pub const Message = union(enum) {
    quit,
    resized,

    text: []const u8,
    newline,
    backspace,

    /// Show the file finder.
    find,
    /// Show the nth file open in the window, counted from zero: cmd+1 to cmd+9.
    tab: u8,
    /// Put the nth file beside what is already split, or take it away again:
    /// cmd+alt+1 to cmd+alt+9.
    split: u8,
    /// Take the file in front off the bar and out of memory: cmd+W.
    close,
    /// Move a selection, not a caret: nothing in a file reads these yet.
    up,
    down,
    /// Escape. Put back whatever was in front of this.
    cancel,

    /// Pixels to move a view by, positive downwards, and where the pointer was
    /// while it happened -- which is what decides whose view moves.
    wheel: struct { delta: f32, at: [2]f32 },
    press: [2]f32,
    move: [2]f32,
    release,

    /// Whether a key was pressed with the modifier that means "this is a
    /// command". Cmd on macOS, Ctrl elsewhere -- either is accepted everywhere,
    /// so one binding is right on every platform and nothing has to ask which
    /// one it is on.
    fn commanded(mod: c.SDL_Keymod) bool {
        return mod & (c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL) != 0;
    }

    /// Null for what nothing here acts on, which is most of what SDL sends.
    ///
    /// `density` is how many pixels a window coordinate is worth. Applying it
    /// here is what lets everything downstream speak in one unit.
    pub fn init(from: *const c.SDL_Event, density: f32) ?Message {
        return switch (from.type) {
            c.SDL_EVENT_QUIT => .quit,
            c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => .resized,

            // Text arrives as finished characters rather than keys; return and
            // backspace are not text and do not arrive as any.
            c.SDL_EVENT_TEXT_INPUT => .{ .text = std.mem.span(from.text.text) },
            c.SDL_EVENT_KEY_DOWN => key: {
                // The digits are read off the scancode rather than the keycode:
                // a modifier turns `1` into something else on most layouts, and
                // what these mean is the key under the finger. They are
                // contiguous, so the key is its own index.
                //
                // Alt rather than shift for the second of them: macOS has taken
                // shift+cmd+3 and shift+cmd+4 for screenshots and never passes
                // them on.
                if (commanded(from.key.mod)) {
                    const code = from.key.scancode;
                    if (code >= c.SDL_SCANCODE_1 and code <= c.SDL_SCANCODE_9) {
                        const which: u8 = @intCast(code - c.SDL_SCANCODE_1);
                        break :key if (from.key.mod & c.SDL_KMOD_ALT != 0)
                            .{ .split = which }
                        else
                            .{ .tab = which };
                    }
                }

                break :key switch (from.key.key) {
                    c.SDLK_RETURN => .newline,
                    c.SDLK_BACKSPACE => .backspace,
                    c.SDLK_UP => .up,
                    c.SDLK_DOWN => .down,
                    c.SDLK_ESCAPE => .cancel,
                    c.SDLK_P => if (commanded(from.key.mod))
                        .find
                    else
                        // Plain `p` is a character, and arrives as text input.
                        null,
                    c.SDLK_W => if (commanded(from.key.mod)) .close else null,
                    else => null,
                };
            },

            // A precise device is reported in tenths of a point, so ten times
            // the delta is how far a finger moved. A notched wheel reports whole
            // lines instead and nothing tells the two apart -- macOS registers
            // one mouse and gives it no name -- so everything is read as points.
            // Negated because SDL counts a wheel positive away from the reader,
            // which is towards the start of the file.
            c.SDL_EVENT_MOUSE_WHEEL => .{ .wheel = .{
                .delta = -from.wheel.y * 10 * density,
                .at = .{ from.wheel.mouse_x * density, from.wheel.mouse_y * density },
            } },

            c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (from.button.button == c.SDL_BUTTON_LEFT)
                .{ .press = .{ from.button.x * density, from.button.y * density } }
            else
                null,
            c.SDL_EVENT_MOUSE_MOTION => .{ .move = .{ from.motion.x * density, from.motion.y * density } },
            c.SDL_EVENT_MOUSE_BUTTON_UP => if (from.button.button == c.SDL_BUTTON_LEFT)
                .release
            else
                null,

            // Exposure belongs to the resize watch, which has already drawn by
            // the time the message arrives here; acting on it would draw twice.
            else => null,
        };
    }
};

/// A key going down, as SDL reports one. The scancode is the key's place on the
/// keyboard and the keycode is what it would type; the bindings below care about
/// one or the other, never both.
fn pressed(scancode: c_uint, keycode: u32, mod: u16) c.SDL_Event {
    var message: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    message.type = c.SDL_EVENT_KEY_DOWN;
    message.key.scancode = scancode;
    message.key.key = keycode;
    message.key.mod = mod;
    return message;
}

test "a digit on its own is a character, not a binding" {
    const message = pressed(c.SDL_SCANCODE_1, c.SDLK_1, 0);
    try std.testing.expectEqual(@as(?Message, null), Message.init(&message, 1));
}

test "cmd and a digit reach that tab, counted from zero" {
    const first = pressed(c.SDL_SCANCODE_1, c.SDLK_1, c.SDL_KMOD_LGUI);
    try std.testing.expectEqual(@as(u8, 0), Message.init(&first, 1).?.tab);

    const ninth = pressed(c.SDL_SCANCODE_9, c.SDLK_9, c.SDL_KMOD_LGUI);
    try std.testing.expectEqual(@as(u8, 8), Message.init(&ninth, 1).?.tab);
}

test "ctrl does what cmd does, on any platform" {
    const message = pressed(c.SDL_SCANCODE_3, c.SDLK_3, c.SDL_KMOD_LCTRL);
    try std.testing.expectEqual(@as(u8, 2), Message.init(&message, 1).?.tab);
}

test "adding alt splits that tab instead of showing it" {
    const message = pressed(c.SDL_SCANCODE_3, c.SDLK_3, c.SDL_KMOD_LGUI | c.SDL_KMOD_LALT);
    try std.testing.expectEqual(@as(u8, 2), Message.init(&message, 1).?.split);
}

test "the keycode a modifier produces is not what a digit is read from" {
    // Holding a modifier turns `3` into `#` on a US layout and into something
    // else again elsewhere. The scancode is the key under the finger either way,
    // and is what these bindings are read from.
    const message = pressed(c.SDL_SCANCODE_3, c.SDLK_HASH, c.SDL_KMOD_LGUI | c.SDL_KMOD_LALT);
    try std.testing.expectEqual(@as(u8, 2), Message.init(&message, 1).?.split);
}

test "the letters are read from the keycode, which is where they are" {
    const find = pressed(c.SDL_SCANCODE_P, c.SDLK_P, c.SDL_KMOD_LGUI);
    try std.testing.expectEqual(Message.find, Message.init(&find, 1).?);

    const shut = pressed(c.SDL_SCANCODE_W, c.SDLK_W, c.SDL_KMOD_LGUI);
    try std.testing.expectEqual(Message.close, Message.init(&shut, 1).?);

    // Without the modifier they are characters, and arrive as text input.
    const typed = pressed(c.SDL_SCANCODE_P, c.SDLK_P, 0);
    try std.testing.expectEqual(@as(?Message, null), Message.init(&typed, 1));
}
