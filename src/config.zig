//! Knobs that get changed while working on the editor, kept apart from the code
//! that reads them. build.zig imports this too, so a path named here is the path
//! the build actually embeds.

/// Embedded at build time, not opened at runtime. Relative to the repo root.
pub const font_path = "assets/DejaVuSans.ttf";

/// Nominal, not pixels: what reaches FreeType is this times the window's display
/// scale, so text is the same size to look at on any display.
pub const font_size = 13;

// -- Theme --------------------------------------------------------------------
//
// The swapchain is a plain UNORM target, so these are the numbers that reach it.
// Alpha on the text multiplies the glyph's coverage rather than replacing it.
//
// The dark pair these replaced: background `.{ 0.07, 0.07, 0.08, 1 }`.

pub const background: [4]f32 = .{ 1, 1, 1, 1 };
pub const text_colour: [4]f32 = .{ 0, 0, 0, 1 };
pub const caret_colour: [4]f32 = .{ 0, 0, 0, 1 };
pub const scrollbar_colour: [4]f32 = .{ 0, 0, 0, 0.28 };

// The healthcheck, the only thing yaz draws that is not a document.

pub const panel_colour: [4]f32 = .{ 0.965, 0.965, 0.975, 1 };
pub const chip_colour: [4]f32 = .{ 0.855, 0.855, 0.875, 1 };

/// Paths and anything else said quietly.
pub const muted_colour: [4]f32 = .{ 0.40, 0.40, 0.44, 1 };

/// Hairlines: under the finder's query, and the leader that ties a chosen
/// filename to the directory it is in.
pub const rule_colour: [4]f32 = .{ 0, 0, 0, 0.14 };

/// Quieter still: the directory in front of a filename, and a count nobody is
/// reading unless they went looking for it.
pub const faint_colour: [4]f32 = .{ 0.62, 0.62, 0.66, 1 };

/// Laid over the document while the finder is up. White rather than black, and
/// not opaque: what is behind stays legible as a ghost, so the window does not
/// feel like it went somewhere else.
pub const scrim_colour: [4]f32 = .{ 1, 1, 1, 0.955 };

/// A tool that runs, and one that does not. Both are said in words as well, so
/// the colour is a second signal rather than the only one.
pub const good_colour: [4]f32 = .{ 0.13, 0.52, 0.28, 1 };
pub const bad_colour: [4]f32 = .{ 0.72, 0.17, 0.17, 1 };
