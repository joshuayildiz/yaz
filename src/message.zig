//! What happened, in the program's own words rather than SDL's.

const std = @import("std");
const builtin = @import("builtin");

const sdl = @import("./sdl.zig");
const c = sdl.c;

/// macOS is the one platform that reports a scroll as a distance. Everywhere
/// else a wheel event is detents, and a detent is a number of lines.
const macos = builtin.target.os.tag == .macos;

const lines_per_notch = 3;

/// What the runtime is asked to do once the model has moved as far as it can on
/// its own: an effect is everything the model cannot do to itself -- the
/// clipboard, the filesystem, a dialog. `Model.update` answers with one rather
/// than performing it, which keeps SDL and the filesystem out of its tests, and
/// whatever performing one produces comes back as a message.
pub const Effect = union(enum) {
    copy: usize,
    paste: usize,
    save: usize,

    /// Which file is waiting for the name is the model's to remember, so there
    /// is nothing to carry here.
    ask_name,

    /// The filesystem watch that keeps the tree live. An effect and not a flag
    /// because starting it registers a callback that pushes SDL events.
    watch,
    unwatch,
};

/// Already in pixels by the time one of these is made, so nothing downstream has
/// to know what a display scale is or what SDL calls things.
pub const Message = union(enum) {
    /// Nothing here acts on, which is most of what SDL sends. Named rather than a
    /// null so `init` hands back a message like any other; the loop drops it.
    none,

    quit,
    resized,
    themed,

    text: []const u8,
    newline,
    backspace,

    find,
    /// cmd+B.
    toggle_tree,
    /// cmd+E: swap the sublime and acme views.
    toggle_view,
    /// Pushed from the library's watcher thread, so it wakes the window rather
    /// than being a keystroke.
    disk_changed,
    /// Show the nth open file, or the tab a press landed on: cmd+1 to cmd+9.
    show: usize,
    /// Put the nth file beside what is split, or take it away: cmd+alt+1 up.
    split: usize,
    /// cmd+W.
    close,
    /// cmd+A.
    select_all,
    /// SDL drops a keystroke whose text is a control character, and a tab is one,
    /// so it arrives as a key or not at all.
    tab,
    /// cmd+X, cmd+C, cmd+V.
    cut,
    copy,
    paste,
    /// cmd+S.
    save,
    /// The path a save dialog answered with. Its file is the model's to remember,
    /// since the answer can take as long as somebody takes to give it.
    named: []const u8,
    up,
    down,
    cancel,

    /// `at` is where the pointer was, which is what decides whose view a wheel
    /// moves.
    wheel: struct { delta: f32, at: [2]f32 },
    /// `extend` is shift held; `clicks` is how many presses in a row, which tells
    /// a click from a double-click.
    press: struct { at: [2]f32, extend: bool, clicks: u8 },
    move: [2]f32,
    release,

    /// Acme's "look", on button 3: the word it lands on is searched for.
    look: [2]f32,

    // What `Model.resolve` turns a raw pointer message into, and what a finished
    // effect loops back as. `update` recurses on the raw ones and mutates on
    // these, so they never reach `resolve`.

    pin: usize,

    /// `extend` moves only this end, leaving the other -- a shifted press or a
    /// drag; without it the selection collapses to the caret.
    caret: struct { column: usize, at: usize, extend: bool = false },

    /// `follow` brings the view to it as an edit does; `warp` brings the pointer
    /// too, so a look steps on to the next occurrence under a still hand.
    selection: struct { column: usize, from: usize, to: usize, follow: bool = false, warp: bool = false },

    /// `pending` is the fraction of a gesture too small to move a whole pixel
    /// yet, carried rather than kept.
    scroll: struct { column: usize, to: f32, pending: f32 = 0 },

    /// Where on the thumb a press took hold. Null lets go.
    grab: struct { column: usize, at: ?f32 },

    /// Also what a paste loops back as.
    insert: struct { column: usize, text: []const u8 },

    saved: usize,

    /// The paths are borrowed from the sidebar's rows, which outlive the call.
    toggle_dir: []const u8,
    open_file: []const u8,
    scroll_tree: f32,

    /// The "this is a command" modifier: cmd on macOS, ctrl elsewhere, either
    /// accepted everywhere. The letters go by this; the digits by `numbered`.
    fn commanded(mod: c.SDL_Keymod) bool {
        return mod & (c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL) != 0;
    }

    /// The two things a digit can mean, or neither -- the one family of bindings
    /// that differs by platform. macOS adds alt for the second because shift is
    /// taken: shift+cmd+3 and shift+cmd+4 are the system's screenshots and never
    /// reach an application. Everywhere else it is alt alone -- what every other
    /// window's tab strip answers to -- and shift for the second.
    fn numbered(mod: c.SDL_Keymod) ?enum { show, split } {
        const alt = mod & c.SDL_KMOD_ALT != 0;

        if (macos) {
            if (!commanded(mod)) return null;
            return if (alt) .split else .show;
        }

        if (commanded(mod) or !alt) return null;
        return if (mod & c.SDL_KMOD_SHIFT != 0) .split else .show;
    }

    /// `.none` for what nothing here acts on. `density` turns a window coordinate
    /// into pixels; `line_height` is already in them.
    pub fn init(from: *const c.SDL_Event, density: f32, line_height: f32) Message {
        // Registered event types are claimed at runtime, so they cannot be cases
        // of the switch below. The path is borrowed; `run` lets go of it once
        // this has been acted on.
        if (sdl.path_chosen != 0 and from.type == sdl.path_chosen) {
            const owned = from.user.data1 orelse return .none;
            const named: [*:0]const u8 = @ptrCast(owned);
            return .{ .named = std.mem.span(named) };
        }
        if (sdl.tree_changed != 0 and from.type == sdl.tree_changed) return .disk_changed;

        return switch (from.type) {
            c.SDL_EVENT_QUIT => .quit,
            c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => .resized,
            c.SDL_EVENT_SYSTEM_THEME_CHANGED => .themed,

            c.SDL_EVENT_TEXT_INPUT => .{ .text = std.mem.span(from.text.text) },
            c.SDL_EVENT_KEY_DOWN => key: {
                // Read off the scancode, not the keycode: a modifier turns `1`
                // into something else on most layouts, and what a digit means is
                // the key under the finger. They are contiguous, so it indexes.
                const code = from.key.scancode;
                if (code >= c.SDL_SCANCODE_1 and code <= c.SDL_SCANCODE_9) {
                    if (numbered(from.key.mod)) |what| {
                        const which: u8 = @intCast(code - c.SDL_SCANCODE_1);
                        break :key switch (what) {
                            .show => .{ .show = which },
                            .split => .{ .split = which },
                        };
                    }
                }

                break :key switch (from.key.key) {
                    c.SDLK_RETURN => .newline,
                    c.SDLK_BACKSPACE => .backspace,
                    c.SDLK_TAB => .tab,
                    c.SDLK_UP => .up,
                    c.SDLK_DOWN => .down,
                    c.SDLK_ESCAPE => .cancel,
                    c.SDLK_P => if (commanded(from.key.mod)) .find else .none,
                    c.SDLK_W => if (commanded(from.key.mod)) .close else .none,
                    c.SDLK_B => if (commanded(from.key.mod)) .toggle_tree else .none,
                    c.SDLK_E => if (commanded(from.key.mod)) .toggle_view else .none,
                    c.SDLK_A => if (commanded(from.key.mod)) .select_all else .none,
                    // Safe to bind because SDL drops a control-character
                    // keystroke: ctrl+C does not also arrive as the 0x03 of it.
                    c.SDLK_X => if (commanded(from.key.mod)) .cut else .none,
                    c.SDLK_C => if (commanded(from.key.mod)) .copy else .none,
                    c.SDLK_V => if (commanded(from.key.mod)) .paste else .none,
                    c.SDLK_S => if (commanded(from.key.mod)) .save else .none,
                    else => .none,
                };
            },

            // macOS reports a precise device in tenths of a point, so ten times
            // it is pixels moved; everywhere else it is detents, each worth
            // `lines_per_notch` lines already in pixels. Negated because SDL
            // counts a wheel positive away from the reader.
            c.SDL_EVENT_MOUSE_WHEEL => .{ .wheel = .{
                .delta = if (macos)
                    -from.wheel.y * 10 * density
                else
                    -from.wheel.y * lines_per_notch * line_height,
                .at = .{ from.wheel.mouse_x * density, from.wheel.mouse_y * density },
            } },

            // Shift is asked for rather than read off the event: SDL puts a
            // modifier on a key but not on a button.
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => switch (from.button.button) {
                c.SDL_BUTTON_LEFT => .{ .press = .{
                    .at = .{ from.button.x * density, from.button.y * density },
                    .extend = c.SDL_GetModState() & c.SDL_KMOD_SHIFT != 0,
                    .clicks = from.button.clicks,
                } },
                c.SDL_BUTTON_RIGHT => .{ .look = .{ from.button.x * density, from.button.y * density } },
                else => .none,
            },
            c.SDL_EVENT_MOUSE_MOTION => .{ .move = .{ from.motion.x * density, from.motion.y * density } },
            c.SDL_EVENT_MOUSE_BUTTON_UP => if (from.button.button == c.SDL_BUTTON_LEFT)
                .release
            else
                .none,

            else => .none,
        };
    }
};

const a_line: f32 = 15;

/// The modifiers that show and split a tab on the platform the tests run on, so
/// a test can name the binding without naming the keys.
const shows: u16 = if (macos) c.SDL_KMOD_LGUI else c.SDL_KMOD_LALT;
const splits: u16 = if (macos)
    c.SDL_KMOD_LGUI | c.SDL_KMOD_LALT
else
    c.SDL_KMOD_LALT | c.SDL_KMOD_LSHIFT;

/// The scancode is the key's place on the keyboard, the keycode what it would
/// type; the bindings care about one or the other, never both.
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
    try std.testing.expectEqual(Message.none, Message.init(&message, 1, a_line));
}

test "the platform's modifier and a digit reach that tab, counted from zero" {
    const first = pressed(c.SDL_SCANCODE_1, c.SDLK_1, shows);
    try std.testing.expectEqual(@as(usize, 0), Message.init(&first, 1, a_line).show);

    const ninth = pressed(c.SDL_SCANCODE_9, c.SDLK_9, shows);
    try std.testing.expectEqual(@as(usize, 8), Message.init(&ninth, 1, a_line).show);
}

test "the second modifier splits that tab instead of showing it" {
    const message = pressed(c.SDL_SCANCODE_3, c.SDLK_3, splits);
    try std.testing.expectEqual(@as(usize, 2), Message.init(&message, 1, a_line).split);
}

test "ctrl still does what cmd does for the letters, on any platform" {
    const shut = pressed(c.SDL_SCANCODE_W, c.SDLK_W, c.SDL_KMOD_LCTRL);
    try std.testing.expectEqual(Message.close, Message.init(&shut, 1, a_line));
}

test "off macOS the digits are alt's, and ctrl has no answer for them" {
    if (macos) return error.SkipZigTest;

    const with_ctrl = pressed(c.SDL_SCANCODE_1, c.SDLK_1, c.SDL_KMOD_LCTRL);
    try std.testing.expectEqual(Message.none, Message.init(&with_ctrl, 1, a_line));

    const with_both = pressed(c.SDL_SCANCODE_1, c.SDLK_1, c.SDL_KMOD_LCTRL | c.SDL_KMOD_LALT);
    try std.testing.expectEqual(Message.none, Message.init(&with_both, 1, a_line));
}

test "on macOS the command key is still what the digits answer to" {
    if (!macos) return error.SkipZigTest;

    // Alt alone is the binding everywhere else, and nothing here.
    const alone = pressed(c.SDL_SCANCODE_1, c.SDLK_1, c.SDL_KMOD_LALT);
    try std.testing.expectEqual(Message.none, Message.init(&alone, 1, a_line));

    const commanded_digit = pressed(c.SDL_SCANCODE_1, c.SDLK_1, c.SDL_KMOD_LCTRL);
    try std.testing.expectEqual(@as(usize, 0), Message.init(&commanded_digit, 1, a_line).show);
}

test "the keycode a modifier produces is not what a digit is read from" {
    // Holding a modifier turns `3` into `#` on a US layout and into something
    // else again elsewhere. The scancode is the key under the finger either way,
    // and is what these bindings are read from.
    const message = pressed(c.SDL_SCANCODE_3, c.SDLK_HASH, splits);
    try std.testing.expectEqual(@as(usize, 2), Message.init(&message, 1, a_line).split);
}

test "the letters are read from the keycode, which is where they are" {
    const find = pressed(c.SDL_SCANCODE_P, c.SDLK_P, c.SDL_KMOD_LGUI);
    try std.testing.expectEqual(Message.find, Message.init(&find, 1, a_line));

    const shut = pressed(c.SDL_SCANCODE_W, c.SDLK_W, c.SDL_KMOD_LGUI);
    try std.testing.expectEqual(Message.close, Message.init(&shut, 1, a_line));

    // Without the modifier they are characters, and arrive as text input.
    const typed = pressed(c.SDL_SCANCODE_P, c.SDLK_P, 0);
    try std.testing.expectEqual(Message.none, Message.init(&typed, 1, a_line));
}

/// A wheel turning, as SDL reports one. `y` counts away from the reader.
fn turned(y: f32) c.SDL_Event {
    var message: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    message.type = c.SDL_EVENT_MOUSE_WHEEL;
    message.wheel.y = y;
    return message;
}

test "a notch is a number of lines, not a distance of its own" {
    // macOS reads the same delta as tenths of a point, and nothing in the event
    // says which of the two sent it.
    if (macos) return error.SkipZigTest;

    // Towards the reader is down the file, which is where the scroll grows.
    const down = Message.init(&turned(-1), 1, a_line);
    try std.testing.expectEqual(@as(f32, lines_per_notch * a_line), down.wheel.delta);

    const up = Message.init(&turned(1), 1, a_line);
    try std.testing.expectEqual(@as(f32, -lines_per_notch * a_line), up.wheel.delta);
}

test "a notch is the same number of lines on a display of any scale" {
    if (macos) return error.SkipZigTest;

    // The density is what the pointer is reported in, not the wheel: a line is
    // already as tall as the display made it.
    const dense = Message.init(&turned(-1), 2, a_line * 2);
    try std.testing.expectEqual(@as(f32, lines_per_notch * a_line * 2), dense.wheel.delta);
}

test "a touchpad's fraction of a notch moves that fraction of the lines" {
    // Windows sends a precision touchpad's scroll as part of a detent rather
    // than as a distance, so proportion is all it takes to stay smooth.
    if (macos) return error.SkipZigTest;

    const nudged = Message.init(&turned(-0.25), 1, a_line);
    try std.testing.expectEqual(@as(f32, lines_per_notch * a_line / 4), nudged.wheel.delta);
}

test "the tab key is a message of its own, not text" {
    // SDL drops a keystroke whose text is a control character and a tab is one,
    // so it arrives as a key or it does not arrive.
    const message = pressed(c.SDL_SCANCODE_TAB, c.SDLK_TAB, 0);
    try std.testing.expectEqual(Message.tab, Message.init(&message, 1, a_line));
}

test "a modifier does not turn the tab key into something else" {
    // Nothing is bound to it yet, but it must not fall through to the digits.
    const message = pressed(c.SDL_SCANCODE_TAB, c.SDLK_TAB, c.SDL_KMOD_LCTRL);
    try std.testing.expectEqual(Message.tab, Message.init(&message, 1, a_line));
}
