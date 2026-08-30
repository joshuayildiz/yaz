//! The program's one `@cImport` of SDL, and the one place it has to be reached
//! around.
//!
//! Two `@cImport` blocks that differ by so much as whitespace generate two
//! unrelated sets of types, and a `*SDL_Window` from one will not pass as a
//! `*SDL_Window` to the other. Everything that touches SDL takes its types from
//! here, so there is never a second block to differ from.

const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

/// SDL reports failures out of band; this is only meaningful right after one.
pub fn lastError() []const u8 {
    return std.mem.span(c.SDL_GetError());
}

/// Pins the window's contents to its top-left corner while it is being resized.
/// macOS only; nothing to do anywhere else.
///
/// A `CAMetalLayer` keeps `CALayer`'s default `contentsGravity`, which is
/// `kCAGravityResize`: when the layer's bounds change and no new frame has
/// arrived yet, the compositor stretches the old one to fit. Dragging a window
/// edge therefore smears the text until the next present catches up, which for
/// a proportional layout reads as the glyphs themselves changing width.
///
/// Top-left leaves the old frame at its own size, in the corner text is laid out
/// from, and leaves the strip the window has just grown into for the redraw
/// during a resize to fill -- which it is already racing to do. The worst case
/// becomes a moment of empty margin rather than a moment of distorted text.
///
/// Must be called after the window has been claimed for a GPU device: the layer
/// does not exist until then.
pub fn anchorContentsTopLeft(window: *c.SDL_Window) void {
    if (builtin.target.os.tag != .macos) return;
    const layer = metalLayer(window) orelse return;
    _ = objc.call(.void, layer, "setContentsGravity:", .{kCAGravityTopLeft});
}

/// Paints the layer's own background, which is what shows in the strip a window
/// has just grown into before a frame arrives to fill it. macOS only.
///
/// Only worth anything alongside `anchorContentsTopLeft`, and made necessary by
/// it: stretching the old frame left no gap to fill, and not stretching it does.
/// The layer's background is unset by default and SDL marks the layer opaque, so
/// that gap composites as black — which against a light theme is the resize
/// flashing dark at the edge and snapping back.
///
/// Must be called after the window has been claimed for a GPU device: the layer
/// does not exist until then.
pub fn setLayerBackground(window: *c.SDL_Window, colour: [4]f32) void {
    if (builtin.target.os.tag != .macos) return;
    const layer = metalLayer(window) orelse return;

    // sRGB rather than a device space, so the number here is the number the
    // shader's clear colour means; a colour created in a device space would be
    // the same triple interpreted differently and would not quite match.
    const cg_colour = CGColorCreateSRGB(colour[0], colour[1], colour[2], colour[3]) orelse return;
    // The layer retains it; this reference has done its job either way.
    defer CGColorRelease(cg_colour);

    _ = objc.call(.void, layer, "setBackgroundColor:", .{cg_colour});
}

/// The `CAMetalLayer` SDL_GPU draws into. SDL owns the view and does not hand it
/// over, but it does say where to find it: the tag it gave the view, and the
/// window it was added to.
fn metalLayer(window: *c.SDL_Window) ?*anyopaque {
    const props = c.SDL_GetWindowProperties(window);
    const ns_window = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse return null;
    const tag = c.SDL_GetNumberProperty(props, c.SDL_PROP_WINDOW_COCOA_METAL_VIEW_TAG_NUMBER, 0);
    if (tag == 0) return null;

    const content_view = objc.call(.id, ns_window, "contentView", .{}) orelse return null;
    const metal_view = objc.call(.id, content_view, "viewWithTag:", .{@as(isize, @intCast(tag))}) orelse return null;
    return objc.call(.id, metal_view, "layer", .{});
}

/// QuartzCore's name for the top-left gravity. Linked rather than spelled out as
/// a string literal here, so the name comes from the framework that defines it;
/// QuartzCore is already on the link line because SDL's Metal backend needs it.
///
/// Reading `contentsGravity` back afterwards returns an equal string rather than
/// this same pointer, so it is the value that matters, not the identity.
extern var kCAGravityTopLeft: ?*anyopaque;

/// A colour in sRGB, which is what `CALayer.backgroundColor` takes: a
/// `CGColorRef`, not an object, so it is passed as the pointer it is.
extern fn CGColorCreateSRGB(red: f64, green: f64, blue: f64, alpha: f64) ?*anyopaque;
extern fn CGColorRelease(color: ?*anyopaque) void;

/// Just enough of the Objective-C runtime to send four messages. Declared by
/// hand rather than `@cImport`ed so that a build for any other target does not
/// need Apple's headers to resolve a file it will not call into.
const objc = struct {
    extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;

    /// Declared as taking nothing, because it takes whatever the message does.
    /// Every call goes through a pointer cast to the signature of the selector
    /// being sent: on arm64 `objc_msgSend` has no variadic form, and calling it
    /// through the wrong prototype puts the arguments in the wrong registers.
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
