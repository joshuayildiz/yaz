//! Putting a shaped line on screen, and asking how wide one is.
//!
//! Shaping belongs to the atlas and a line's bytes belong to the document. What
//! is left is placing the result, which every component that draws text does the
//! same way and did until now in three copies.

const glyph_atlas = @import("./glyph_atlas.zig");
const LineLayout = glyph_atlas.LineLayout;

const painter_mod = @import("./painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;

/// Adds `layout`'s glyphs under `key`, with the line starting at `at` and
/// sitting on it as a baseline.
///
/// A layout is held in its own coordinates precisely so that this is the whole
/// of moving one: an add per glyph, and no reshaping when a line only moved.
pub fn draw(painter: *Painter, key: Key, layout: *const LineLayout, at: [2]f32) !void {
    try painter.reserve(layout.sprites.items.len);
    for (layout.sprites.items) |sprite| {
        try painter.add(key, .{
            .dest = .{ sprite.dest[0] + at[0], sprite.dest[1] + at[1] },
            .source = sprite.source,
            .size = sprite.size,
        });
    }
}

/// How wide a shaped line is. `shapeLine` leaves a last caret at the pen after
/// the final glyph, which is exactly the line's advance.
pub fn advance(layout: *const LineLayout) f32 {
    const carets = layout.carets.items;
    return if (carets.len == 0) 0 else carets[carets.len - 1].x;
}
