//! Knobs that get changed while working on the editor, kept apart from the code
//! that reads them. build.zig imports this too, so a path named here is the path
//! the build actually embeds.

/// Embedded into the binary at build time, not opened at runtime. Relative to
/// the repository root.
pub const font_path = "assets/DejaVuSans.ttf";

/// Nominal font size. Not pixels: what reaches FreeType is this times the
/// window's display scale, so the text is the same size to look at on a dense
/// display as on a coarse one and only the number of pixels spent on it changes.
pub const font_size = 32;

// -- Theme --------------------------------------------------------------------
//
// Linear, not sRGB, and premultiplied by nothing: the swapchain is an ordinary
// UNORM target, so these are the numbers that reach it. Alpha is honoured on the
// text, where it multiplies the glyph's coverage rather than replacing it.

/// What the window is cleared to before a glyph is drawn.
pub const background: [4]f32 = .{ 1, 1, 1, 1 };

/// What glyphs and the caret are drawn in. The atlas holds coverage rather than
/// colour, so this is the colour and the coverage is the alpha.
///
/// The softened pair the dark theme was built from, if the pure one is too hard
/// to sit in front of: background `.{ 0.93, 0.93, 0.92, 1 }` with text
/// `.{ 0.07, 0.07, 0.08, 1 }`.
pub const text_colour: [4]f32 = .{ 0, 0, 0, 1 };

/// What the caret is drawn in. The same as the text by default, which is what it
/// looked like when it had no choice; it is a separate knob because the caret is
/// the one mark on screen that has to be found without looking for it, and that
/// is a reason to let it differ rather than an argument that it should.
pub const caret_colour: [4]f32 = .{ 0, 0, 0, 1 };
