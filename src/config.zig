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
