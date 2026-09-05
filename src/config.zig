//! Knobs that get changed while working on the editor, kept apart from the code
//! that reads them. build.zig imports this too, so a path named here is the path
//! the build actually embeds.

/// Embedded at build time, not opened at runtime. Relative to the repo root.
pub const font_path = "assets/DejaVuSansMono.ttf";

/// Nominal, not pixels: what reaches FreeType is this times the window's display
/// scale, so text is the same size to look at on any display.
pub const font_size = 13;

/// One step of indentation, as the text it is as wide as. A digit, not a space:
/// a proportional font's space is too thin to indent with, and a digit is its
/// one reliably wide, fixed-width glyph.
pub const indent_stop = "0";

/// A count rather than a width, so a tab and `tab_stops` spaces come out the same
/// distance by construction.
pub const tab_stops = 4;

// -- Theme --------------------------------------------------------------------
//
// Colours are named by what they are *for*, not by what they look like: the look
// is the theme's, chosen at the last moment in the renderer, so the same frame
// reads light or dark without anything being rebuilt. The swapchain is a plain
// UNORM target, so these are the numbers that reach it, and alpha on text
// multiplies the glyph's coverage rather than replacing it.

const std = @import("std");

/// Followed from the system; decides which palette a `Colour` resolves against.
pub const Theme = enum { light, dark };

/// A semantic colour role. A `Key` carries one of these rather than an rgba.
pub const Colour = enum {
    background,
    text,
    caret,
    scrollbar,
    /// The band under selected text.
    text_selection,
    /// A surface floating over the file. `chip` is the recessed strip a tab or
    /// tree row sits in; `edge` the hairline round a floating surface.
    panel,
    chip,
    edge,
    /// The finder's chosen row.
    selection,
    /// Said quietly (a path), and quieter still (a directory, a count).
    muted,
    faint,
    /// A tool that runs, and one that does not.
    good,
    bad,
};

const Palette = std.EnumArray(Colour, [4]f32);

/// Black text on white.
const light: Palette = .init(.{
    .background = .{ 1, 1, 1, 1 },
    .text = .{ 0, 0, 0, 1 },
    .caret = .{ 0, 0, 0, 1 },
    .scrollbar = .{ 0, 0, 0, 0.28 },
    .text_selection = .{ 0.99, 0.86, 0.36, 1 },
    .panel = .{ 0.965, 0.965, 0.975, 1 },
    .chip = .{ 0.855, 0.855, 0.875, 1 },
    .edge = .{ 0.78, 0.78, 0.81, 1 },
    .selection = .{ 0.855, 0.865, 0.90, 1 },
    .muted = .{ 0.40, 0.40, 0.44, 1 },
    .faint = .{ 0.62, 0.62, 0.66, 1 },
    .good = .{ 0.13, 0.52, 0.28, 1 },
    .bad = .{ 0.72, 0.17, 0.17, 1 },
});

/// Off-white on near-black. The greys flip and the selection amber darkens so
/// light text reads on it.
const dark: Palette = .init(.{
    .background = .{ 0.08, 0.08, 0.10, 1 },
    .text = .{ 0.90, 0.90, 0.93, 1 },
    .caret = .{ 0.90, 0.90, 0.93, 1 },
    .scrollbar = .{ 1, 1, 1, 0.28 },
    .text_selection = .{ 0.46, 0.37, 0.12, 1 },
    .panel = .{ 0.14, 0.14, 0.17, 1 },
    .chip = .{ 0.13, 0.13, 0.16, 1 },
    .edge = .{ 0.30, 0.30, 0.34, 1 },
    .selection = .{ 0.22, 0.25, 0.34, 1 },
    .muted = .{ 0.60, 0.60, 0.65, 1 },
    .faint = .{ 0.45, 0.45, 0.50, 1 },
    .good = .{ 0.42, 0.80, 0.52, 1 },
    .bad = .{ 0.95, 0.48, 0.48, 1 },
});

/// The one place a `Colour` becomes numbers, called by the renderer per draw.
pub fn rgba(theme: Theme, colour: Colour) [4]f32 {
    return (switch (theme) {
        .light => light,
        .dark => dark,
    }).get(colour);
}
