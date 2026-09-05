//! The program's one `@cImport` of SDL, and the one place it has to be reached
//! around.
//!
//! Two `@cImport` blocks differing by so much as whitespace generate two
//! unrelated sets of types, and a `*SDL_Window` from one will not pass as one
//! to the other. Everything that touches SDL takes its types from here.

const std = @import("std");
const builtin = @import("builtin");

const config = @import("./config.zig");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

/// The system's light/dark preference, followed for the theme. Unknown -- a
/// platform with nothing to say -- is taken as light, the default a window opens
/// on. Read fresh each redraw, and `SDL_EVENT_SYSTEM_THEME_CHANGED` is what asks
/// for one when it moves.
pub fn systemTheme() config.Theme {
    return switch (c.SDL_GetSystemTheme()) {
        c.SDL_SYSTEM_THEME_DARK => .dark,
        else => .light,
    };
}

/// The event a save dialog's answer comes back on. Zero until `registerEvents`
/// has run, which is also how anything reading it knows there is one.
///
/// The dialog is asynchronous, and SDL says its callback "may be invoked from
/// the same thread or from a different one, depending on the OS's constraints".
/// So the callback does the one thing that is safe from anywhere -- push an
/// event -- and the answer is read where every other event is read.
pub var path_chosen: u32 = 0;

/// The event a filesystem change pushes to wake the window. Zero until
/// `registerEvents`, the same as `path_chosen` and for the same reason: the
/// library's watcher runs on a thread of its own, so the one thing it does from
/// there is push this, and the tree is rebuilt where every other event is read.
pub var tree_changed: u32 = 0;

/// Claims the two event types above, contiguously. After `SDL_Init`, and once.
pub fn registerEvents() bool {
    const first = c.SDL_RegisterEvents(2);
    if (first == 0) return false;
    path_chosen = first;
    tree_changed = first + 1;
    return true;
}

/// Wakes the window to say the tree changed. Safe from any thread, which is
/// what it is for: it is called from the library's watcher.
pub fn pushTreeChanged() void {
    if (tree_changed == 0) return;
    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    event.type = tree_changed;
    _ = c.SDL_PushEvent(&event);
}

/// Opens a dialog asking where to put a file that has no name yet.
///
/// The answer arrives as a `path_chosen` event, or does not arrive: a dialog
/// that was cancelled is not an answer, and leaves the file as it was.
pub fn askWhereToSave(window: ?*c.SDL_Window) void {
    c.SDL_ShowSaveFileDialog(chosePath, null, window, null, 0, null);
}

/// Lets go of the path a `path_chosen` event carries. Does nothing to any other
/// event, and nothing the second time.
pub fn releasePath(event: *c.SDL_Event) void {
    if (path_chosen == 0 or event.type != path_chosen) return;
    if (event.user.data1) |owned| c.SDL_free(owned);
    event.user.data1 = null;
}

/// Runs on whichever thread the platform finished its dialog on, so it touches
/// nothing but SDL.
fn chosePath(_: ?*anyopaque, filelist: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    // Null is a failure and a pointer to null is a cancel. Neither is worth an
    // event: both leave the file exactly as it was.
    if (filelist == null or filelist[0] == null) return;

    // The list is freed as this returns and the event outlives it. Copied with
    // SDL's allocator rather than the program's, which is not this thread's to
    // reach.
    const copy = c.SDL_strdup(filelist[0]);
    if (copy == null) return;

    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    event.type = path_chosen;
    event.user.data1 = copy;
    if (!c.SDL_PushEvent(&event)) c.SDL_free(copy);
}

/// SDL reports failures out of band; this is only meaningful right after one.
pub fn lastError() []const u8 {
    return std.mem.span(c.SDL_GetError());
}

/// Pins the window's contents to its top-left corner while it is being resized.
/// macOS only. Call after the window is claimed for a GPU device; the layer does
/// not exist before that.
///
/// A `CAMetalLayer` keeps `CALayer`'s default `kCAGravityResize`, which stretches
/// the last frame over the new bounds until a new one lands. On proportional
/// text that reads as the glyphs themselves changing width.
pub fn anchorContentsTopLeft(window: *c.SDL_Window) void {
    if (builtin.target.os.tag != .macos) return;
    const layer = metalLayer(window) orelse return;
    _ = objc.call(.void, layer, "setContentsGravity:", .{kCAGravityTopLeft});
}

/// Paints what shows in the strip a window has just grown into. macOS only, and
/// only needed because `anchorContentsTopLeft` leaves such a strip: the layer's
/// background is unset and SDL marks the layer opaque, so it composites as black.
pub fn setLayerBackground(window: *c.SDL_Window, colour: [4]f32) void {
    if (builtin.target.os.tag != .macos) return;
    const layer = metalLayer(window) orelse return;

    // sRGB so the triple means what the shader's clear colour means.
    const cg_colour = CGColorCreateSRGB(colour[0], colour[1], colour[2], colour[3]) orelse return;
    // The layer retains it.
    defer CGColorRelease(cg_colour);

    _ = objc.call(.void, layer, "setBackgroundColor:", .{cg_colour});
}

/// Takes cmd+W back off the menu bar. macOS only, and only needed because SDL
/// puts it there: with no nib to load it builds a default menu bar, whose Window
/// menu has a Close item bound to it.
///
/// A menu's key equivalent is matched before the key reaches the application, so
/// the window would close and nothing here would ever see the keystroke. The
/// item is left in place and still closes the window when it is chosen; it just
/// stops holding the shortcut.
pub fn unbindCloseShortcut() void {
    if (builtin.target.os.tag != .macos) return;

    const class = objc.class("NSApplication") orelse return;
    const app = objc.call(.id, class, "sharedApplication", .{}) orelse return;
    const menu = objc.call(.id, app, "windowsMenu", .{}) orelse return;

    const titled = objc.string("Close") orelse return;
    const item = objc.call(.id, menu, "itemWithTitle:", .{titled}) orelse return;

    const nothing = objc.string("") orelse return;
    objc.call(.void, item, "setKeyEquivalent:", .{nothing});
}

/// The `CAMetalLayer` SDL_GPU draws into. SDL will not hand over the view it
/// made, but it does publish where to find it.
fn metalLayer(window: *c.SDL_Window) ?*anyopaque {
    const props = c.SDL_GetWindowProperties(window);
    const ns_window = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse return null;
    const tag = c.SDL_GetNumberProperty(props, c.SDL_PROP_WINDOW_COCOA_METAL_VIEW_TAG_NUMBER, 0);
    if (tag == 0) return null;

    const content_view = objc.call(.id, ns_window, "contentView", .{}) orelse return null;
    const metal_view = objc.call(.id, content_view, "viewWithTag:", .{@as(isize, @intCast(tag))}) orelse return null;
    return objc.call(.id, metal_view, "layer", .{});
}

extern var kCAGravityTopLeft: ?*anyopaque;

/// `CALayer.backgroundColor` takes a `CGColorRef`, not an object.
extern fn CGColorCreateSRGB(red: f64, green: f64, blue: f64, alpha: f64) ?*anyopaque;
extern fn CGColorRelease(color: ?*anyopaque) void;

/// Just enough of the Objective-C runtime to send four messages. Declared by
/// hand rather than `@cImport`ed, so other targets need no Apple headers to
/// resolve a file they never call into.
const objc = struct {
    extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
    extern fn objc_getClass(name: [*:0]const u8) ?*anyopaque;

    fn class(name: [*:0]const u8) ?*anyopaque {
        return objc_getClass(name);
    }

    /// An NSString, which two of the selectors below want and neither will make.
    fn string(text: [*:0]const u8) ?*anyopaque {
        return call(.id, class("NSString") orelse return null, "stringWithUTF8String:", .{text});
    }

    /// Every call casts this to the selector's own signature: arm64 has no
    /// variadic `objc_msgSend`, and the wrong prototype puts the arguments in
    /// the wrong registers.
    extern fn objc_msgSend() void;

    const Return = enum { id, void };

    fn call(comptime returns: Return, receiver: *anyopaque, comptime selector: [*:0]const u8, args: anytype) switch (returns) {
        .id => ?*anyopaque,
        .void => void,
    } {
        const Result = switch (returns) {
            .id => ?*anyopaque,
            .void => void,
        };
        const Args = @TypeOf(args);
        const fields = @typeInfo(Args).@"struct".fields;

        const Fn = switch (fields.len) {
            0 => *const fn (*anyopaque, ?*anyopaque) callconv(.c) Result,
            1 => *const fn (*anyopaque, ?*anyopaque, fields[0].type) callconv(.c) Result,
            else => @compileError("objc.call takes at most one argument"),
        };

        const send: Fn = @ptrCast(&objc_msgSend);
        const sel = sel_registerName(selector);
        return switch (fields.len) {
            0 => send(receiver, sel),
            1 => send(receiver, sel, args[0]),
            else => unreachable,
        };
    }
};
