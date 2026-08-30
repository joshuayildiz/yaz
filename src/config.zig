//! Knobs that get changed while working on the editor, kept apart from the code
//! that reads them. build.zig imports this too, so a path named here is the path
//! the build actually embeds.

/// Embedded at build time, not opened at runtime. Relative to the repo root.
pub const font_path = "assets/DejaVuSans.ttf";

/// Nominal, not pixels: what reaches FreeType is this times the window's display
/// scale, so text is the same size to look at on any display.
pub const font_size = 10;

// -- Theme --------------------------------------------------------------------
//
// The swapchain is a plain UNORM target, so these are the numbers that reach it.
// Alpha on the text multiplies the glyph's coverage rather than replacing it.
//
// The dark pair these replaced: background `.{ 0.07, 0.07, 0.08, 1 }`.

pub const background: [4]f32 = .{ 1, 1, 1, 1 };
pub const text_colour: [4]f32 = .{ 0, 0, 0, 1 };
pub const caret_colour: [4]f32 = .{ 0, 0, 0, 1 };
