//! What happened, in the program's own words rather than SDL's.

const std = @import("std");
const builtin = @import("builtin");

const sdl = @import("./sdl.zig");
const c = sdl.c;

/// macOS is the one platform that reports a scroll as a distance. Everywhere
/// else a wheel event is detents, and a detent is a number of lines.
const macos = builtin.target.os.tag == .macos;

/// How far one detent goes. Three is what Windows scrolls by default, and what
/// the desktops elsewhere settled on; a wheel that moved by some distance of
/// its own would be the only thing on the machine that did.
const lines_per_notch = 3;

/// What the runtime is asked to go and do, once the model has moved as far as
/// it can on its own.
///
/// A message is everything the model can do to itself; an effect is everything
/// it cannot -- the clipboard, the filesystem, a dialog. `Model.update` answers
/// with one rather than performing it, which is what keeps SDL and the
/// filesystem out of every branch of it, and out of its tests.
///
/// Whatever performing one produces comes back in as a message, like anything
/// else that ever moves the model.
pub const Effect = union(enum) {
    /// The nth column's selection, to the system clipboard.
    copy: usize,

    /// The system clipboard, into the nth column over whatever is selected.
    paste: usize,

    /// The nth column's file, to the path it was opened from.
    save: usize,

    /// Where to put a file that has no name yet. Which file is waiting for the
    /// answer is the model's to remember, so there is nothing to say here.
    ask_name,

    /// Start or stop the filesystem watch that keeps the sidebar tree live.
    /// Gated on the sidebar being open, so a closed tree wakes the window for
    /// nothing -- which is the whole of why these are effects and not just a
    /// flag flipped in the model.
    watch,
    unwatch,

    /// Several of these, in order. Owned, and freed by whoever performs it: the
    /// slice a caller writes at a return is gone by the time it is walked.
    batch: []const Effect,

    /// Gathers effects into one, copying the list somewhere that outlives the
    /// call so a stack literal survives being handed over.
    pub fn gather(allocator: std.mem.Allocator, these: []const Effect) !Effect {
        return .{ .batch = try allocator.dupe(Effect, these) };
    }
};

/// Already in pixels by the time one of these is made, so nothing that handles
/// one has to know what a display scale is, and nothing that handles one has to
/// know what SDL calls things.
pub const Message = union(enum) {
    /// Nothing here acts on, which is most of what SDL sends: a key with no
    /// binding, an exposure the resize watch has already drawn, an event of a
    /// kind yaz does not read. Named rather than left as a null so `init` says
    /// what it means and hands back a message like any other; the loop drops it.
    none,

    quit,
    resized,

    text: []const u8,
    newline,
    backspace,

    /// Show the file finder.
    find,
    /// Open or close the sidebar tree: cmd+B.
    toggle_tree,
    /// The tree the sidebar shows changed on disk. Pushed from the library's
    /// watcher, so it wakes the window rather than being a keystroke.
    disk_changed,
    /// Show the nth file open in the window, counted from zero: cmd+1 to cmd+9,
    /// or the tab a press landed on. Named for what it asks for rather than for
    /// the strip it is asked from, which leaves `tab` to mean the key.
    show: usize,
    /// Put the nth file beside what is already split, or take it away again:
    /// cmd+alt+1 to cmd+alt+9.
    split: usize,
    /// Take the file in front off the bar and out of memory: cmd+W.
    close,
    /// Take the whole file: cmd+A.
    select_all,
    /// The tab key. Not text and does not arrive as any: SDL drops a keystroke
    /// whose text is a control character, and a tab is one.
    tab,
    /// The selection to the system clipboard and back: cmd+X, cmd+C, cmd+V.
    cut,
    copy,
    paste,
    /// Write the focused file back to where it came from: cmd+S.
    save,
    /// Where to put the file that had no name. The window's, not a column's:
    /// the file that asked is remembered by the model, since the answer can
    /// take as long as somebody takes to give it.
    named: []const u8,
    /// Move a selection, not a caret: nothing in a file reads these yet.
    up,
    down,
    /// Escape. Put back whatever was in front of this.
    cancel,

    /// Pixels to move a view by, positive downwards, and where the pointer was
    /// while it happened -- which is what decides whose view moves.
    wheel: struct { delta: f32, at: [2]f32 },
    /// `extend` is shift being held, which keeps the far end of the selection
    /// where it is instead of starting a new one. `clicks` is how many presses
    /// in a row this is, which is what tells a click from a double-click.
    press: struct { at: [2]f32, extend: bool, clicks: u8 },
    move: [2]f32,
    release,

    /// Button 3, and where it fell: acme's "look". The word it lands on is what
    /// gets searched for, so a column can jump to the next place that word
    /// appears rather than putting a caret down.
    look: [2]f32,

    // -- Resolved intents ----------------------------------------------------
    //
    // What `Model.resolve` turns a raw pointer message into, and what an effect
    // that finished loops back as. `update` recurses on the raw ones and mutates
    // on these; nothing but `update` itself produces them, so they never reach
    // `resolve`.

    /// Keep the nth tab: promote it out of being the scratch preview, so the
    /// next file opened does not replace it. What a double-click on a tab asks
    /// for.
    pin: usize,

    /// Put the caret at a byte offset in the nth column. `extend` leaves the far
    /// end of the selection where it is and moves only this one, which is what a
    /// shifted press and a drag both do; without it the selection collapses.
    caret: struct { column: usize, at: usize, extend: bool = false },

    /// Both ends of a selection at once. `follow` brings the view to it the way
    /// an edit does; `warp` brings the pointer too, which is what lets a look
    /// step on to the next occurrence under a still hand. A drag sets neither.
    selection: struct { column: usize, from: usize, to: usize, follow: bool = false, warp: bool = false },

    /// The top of the nth column's view, in pixels. `pending` is the fraction of
    /// a gesture too small to have moved a whole pixel yet, carried rather than
    /// kept, so a scroll that only moves the fraction changes nothing on screen.
    scroll: struct { column: usize, to: f32, pending: f32 = 0 },

    /// Where on the nth column's scrollbar thumb a press took hold. Null lets go.
    grab: struct { column: usize, at: ?f32 },

    /// Give the nth column the keyboard, without moving anything in it. What a
    /// press on an empty column says.
    focus: usize,

    /// Type text into the nth column over whatever is selected. Carries the
    /// bytes, so it is also what a paste loops back as.
    insert: struct { column: usize, text: []const u8 },

    /// Take out what is selected in the nth column, leaving the caret where it
    /// began. Nothing selected takes nothing out.
    delete_selection: usize,

    /// The nth column's file has been written: clears the mark on its tab. What
    /// an `Effect.save` that worked loops back as.
    saved: usize,

    /// Open or close one folder in the tree, open one file in the focused
    /// column, or move the list. The paths are borrowed from the sidebar's own
    /// rows, which outlive the call, so nothing here owns memory.
    toggle_dir: []const u8,
    open_file: []const u8,
    scroll_tree: f32,

    /// Whether a key was pressed with the modifier that means "this is a
    /// command". Cmd on macOS, Ctrl elsewhere -- either is accepted everywhere,
    /// so one binding is right on every platform and nothing has to ask which
    /// one it is on.
    ///
    /// The letters go by this. The digits do not: see `numbered`.
    fn commanded(mod: c.SDL_Keymod) bool {
        return mod & (c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL) != 0;
    }

    /// The two things a digit can mean, or neither.
    ///
    /// The one family of bindings that is not the same everywhere. macOS holds
    /// the command key and adds alt for the second of them, because shift is
    /// not available to it: shift+cmd+3 and shift+cmd+4 are the system's
    /// screenshots and never reach an application.
    ///
    /// Everywhere else it is alt on its own, which is what the tab strip of
    /// every other window on those machines answers to, and shift for the
    /// second. Ctrl says nothing about a digit there -- with alt meaning a tab,
    /// ctrl+1 and ctrl+alt+1 are chords this no longer has an answer for.
    fn numbered(mod: c.SDL_Keymod) ?enum { show, split } {
        const alt = mod & c.SDL_KMOD_ALT != 0;

        if (macos) {
            if (!commanded(mod)) return null;
            return if (alt) .split else .show;
        }

        if (commanded(mod) or !alt) return null;
        return if (mod & c.SDL_KMOD_SHIFT != 0) .split else .show;
    }

    /// `.none` for what nothing here acts on, which is most of what SDL sends.
    ///
    /// `density` is how many pixels a window coordinate is worth, and
    /// `line_height` is how tall a line already is in them. Applying both here
    /// is what lets everything downstream speak in one unit.
    pub fn init(from: *const c.SDL_Event, density: f32, line_height: f32) Message {
        // Asked before the switch because the type is claimed at runtime and
        // cannot be one of its cases. The path is borrowed the way a text
        // event's characters are: `run` lets go of it once this has been acted
        // on.
        if (sdl.path_chosen != 0 and from.type == sdl.path_chosen) {
            const owned = from.user.data1 orelse return .none;
            const named: [*:0]const u8 = @ptrCast(owned);
            return .{ .named = std.mem.span(named) };
        }

        // Carries nothing: which paths changed is the library's to have already
        // folded into its index, and the tree re-reads that whole rather than
        // acting on one path.
        if (sdl.tree_changed != 0 and from.type == sdl.tree_changed) return .disk_changed;

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
                    c.SDLK_P => if (commanded(from.key.mod))
                        .find
                    else
                        // Plain `p` is a character, and arrives as text input.
                        .none,
                    c.SDLK_W => if (commanded(from.key.mod)) .close else .none,
                    c.SDLK_B => if (commanded(from.key.mod)) .toggle_tree else .none,
                    c.SDLK_A => if (commanded(from.key.mod)) .select_all else .none,
                    // The letters are safe to bind: SDL drops a keystroke whose
                    // text is a control character, so ctrl+C does not also
                    // arrive as the 0x03 Windows makes of it.
                    c.SDLK_X => if (commanded(from.key.mod)) .cut else .none,
                    c.SDLK_C => if (commanded(from.key.mod)) .copy else .none,
                    c.SDLK_V => if (commanded(from.key.mod)) .paste else .none,
                    c.SDLK_S => if (commanded(from.key.mod)) .save else .none,
                    else => .none,
                };
            },

            // What the delta counts is the platform's business. macOS reports a
            // precise device in tenths of a point, so ten times it is how far a
            // finger moved; everywhere else it is detents, and a detent is
            // `lines_per_notch` lines. Reading detents as points was ten pixels
            // a notch on Windows -- two thirds of a line, whatever the display
            // scale, against the three lines every other window there moves.
            //
            // A line is measured in pixels already, so only the point path
            // wants the density. A Windows touchpad sends a fraction of a
            // detent and gets that fraction of the lines.
            //
            // Negated because SDL counts a wheel positive away from the reader,
            // which is towards the start of the file.
            c.SDL_EVENT_MOUSE_WHEEL => .{ .wheel = .{
                .delta = if (macos)
                    -from.wheel.y * 10 * density
                else
                    -from.wheel.y * lines_per_notch * line_height,
                .at = .{ from.wheel.mouse_x * density, from.wheel.mouse_y * density },
            } },

            // The modifier is asked for rather than read off the event: SDL puts
            // one on a key but not on a button, and shift is the difference
            // between starting a selection and extending the one already there.
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => switch (from.button.button) {
                c.SDL_BUTTON_LEFT => .{ .press = .{
                    .at = .{ from.button.x * density, from.button.y * density },
                    .extend = c.SDL_GetModState() & c.SDL_KMOD_SHIFT != 0,
                    .clicks = from.button.clicks,
                } },
                // Button 3 is acme's look: a search, not a caret, so it says
                // where it fell and lets the column work out the rest.
                c.SDL_BUTTON_RIGHT => .{ .look = .{ from.button.x * density, from.button.y * density } },
                else => .none,
            },
            c.SDL_EVENT_MOUSE_MOTION => .{ .move = .{ from.motion.x * density, from.motion.y * density } },
            c.SDL_EVENT_MOUSE_BUTTON_UP => if (from.button.button == c.SDL_BUTTON_LEFT)
                .release
            else
                .none,

            // Exposure belongs to the resize watch, which has already drawn by
            // the time the message arrives here; acting on it would draw twice.
            else => .none,
        };
    }
};

/// A line to measure the tests in. The bindings do not care what it is; the
/// wheel counts its notches in it.
const a_line: f32 = 15;

/// What means "show the nth file" and "put it beside what is there" on the
/// platform the tests are running on, so a test can say which binding it means
/// without saying which keys that is.
const shows: u16 = if (macos) c.SDL_KMOD_LGUI else c.SDL_KMOD_LALT;
const splits: u16 = if (macos)
    c.SDL_KMOD_LGUI | c.SDL_KMOD_LALT
else
    c.SDL_KMOD_LALT | c.SDL_KMOD_LSHIFT;

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

    // What used to show a tab.
    const with_ctrl = pressed(c.SDL_SCANCODE_1, c.SDLK_1, c.SDL_KMOD_LCTRL);
    try std.testing.expectEqual(Message.none, Message.init(&with_ctrl, 1, a_line));

    // And what used to split one.
    const with_both = pressed(c.SDL_SCANCODE_1, c.SDLK_1, c.SDL_KMOD_LCTRL | c.SDL_KMOD_LALT);
    try std.testing.expectEqual(Message.none, Message.init(&with_both, 1, a_line));
}

test "on macOS the command key is still what the digits answer to" {
    if (!macos) return error.SkipZigTest;

    // Alt on its own is the binding everywhere else, and nothing here.
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
