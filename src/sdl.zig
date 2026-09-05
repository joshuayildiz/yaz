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

/// Unknown -- a platform with nothing to say -- is taken as light.
pub fn systemTheme() config.Theme {
    return switch (c.SDL_GetSystemTheme()) {
        c.SDL_SYSTEM_THEME_DARK => .dark,
        else => .light,
    };
}

/// The event a save dialog's answer comes back on. Zero until `registerEvents`.
/// SDL may invoke the dialog callback on any thread, so it does the one thing
/// safe from anywhere -- push an event -- read where every other event is.
pub var path_chosen: u32 = 0;

/// The event a filesystem change pushes to wake the window. Zero until
/// `registerEvents`, and pushed from the library's watcher thread like the above.
pub var tree_changed: u32 = 0;

/// Claims the two event types above, contiguously. After `SDL_Init`, and once.
pub fn registerEvents() bool {
    const first = c.SDL_RegisterEvents(2);
    if (first == 0) return false;
    path_chosen = first;
    tree_changed = first + 1;
    return true;
}

/// Safe from any thread: it is called from the library's watcher.
pub fn pushTreeChanged() void {
    if (tree_changed == 0) return;
    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    event.type = tree_changed;
    _ = c.SDL_PushEvent(&event);
}

/// The answer arrives as a `path_chosen` event, or -- if cancelled -- not at all.
pub fn askWhereToSave(window: ?*c.SDL_Window) void {
    c.SDL_ShowSaveFileDialog(chosePath, null, window, null, 0, null);
}

/// Lets go of the path a `path_chosen` event carries. A no-op on any other event.
pub fn releasePath(event: *c.SDL_Event) void {
    if (path_chosen == 0 or event.type != path_chosen) return;
    if (event.user.data1) |owned| c.SDL_free(owned);
    event.user.data1 = null;
}

/// Runs on whichever thread the platform finished its dialog on, so it touches
/// nothing but SDL.
fn chosePath(_: ?*anyopaque, filelist: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    // Null is a failure, a pointer to null a cancel; neither is worth an event.
    if (filelist == null or filelist[0] == null) return;

    // The list is freed as this returns, so copy it -- with SDL's allocator, the
    // program's not being this thread's to reach.
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

/// macOS only, and only after the window is claimed for a GPU device: a
/// `CAMetalLayer` keeps `CALayer`'s default `kCAGravityResize`, which stretches
/// the last frame over the new bounds -- on text, glyphs changing width -- until
/// a new frame lands.
pub fn anchorContentsTopLeft(window: *c.SDL_Window) void {
    if (builtin.target.os.tag != .macos) return;
    const layer = metalLayer(window) orelse return;
    _ = objc.call(.void, layer, "setContentsGravity:", .{kCAGravityTopLeft});
}

/// Paints the strip `anchorContentsTopLeft` leaves as a window grows. macOS
/// only, and only needed because the layer's background is unset and SDL marks
/// it opaque, so it would composite as black. No-op elsewhere.
pub fn setLayerBackground(window: *c.SDL_Window, colour: [4]f32) void {
    if (builtin.target.os.tag != .macos) return;
    const layer = metalLayer(window) orelse return;

    // sRGB so the triple means what the shader's clear colour means.
    const cg_colour = CGColorCreateSRGB(colour[0], colour[1], colour[2], colour[3]) orelse return;
    // The layer retains it.
    defer CGColorRelease(cg_colour);

    _ = objc.call(.void, layer, "setBackgroundColor:", .{cg_colour});
}

/// Takes cmd+W back off SDL's default macOS menu bar. A menu key equivalent is
/// matched before the key reaches the application, so the window would close and
/// nothing here would ever see the keystroke. The Close item stays; it just
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

/// The `CAMetalLayer` SDL_GPU draws into. SDL will not hand over the view, but
/// publishes where to find it.
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
/// hand rather than `@cImport`ed, so other targets need no Apple headers.
const objc = struct {
    extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
    extern fn objc_getClass(name: [*:0]const u8) ?*anyopaque;

    fn class(name: [*:0]const u8) ?*anyopaque {
        return objc_getClass(name);
    }

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
