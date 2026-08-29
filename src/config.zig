//! Knobs that get changed while working on the editor, kept apart from the code
//! that reads them. build.zig imports this too, so a path named here is the path
//! the build actually embeds.

/// Embedded into the binary at build time, not opened at runtime. Relative to
/// the repository root.
pub const font_path = "assets/DejaVuSans.ttf";

/// Rasterisation size, in pixels. The atlas is built once at this size, so
/// changing it is a rebuild rather than a runtime setting.
pub const font_pixel_size = 32;
