//! A tab per file open in this window, along the top.
//!
//! Each is as wide as the name in it, packed from the left, so the bar reads as
//! labels rather than as a grid: a row of equal shares is the wrong shape for a
//! row of words, which is why this lays its own tabs out.
//!
//! It owns nothing. Which files exist, which are on screen and which is being
//! typed into are read off the model, so the bar cannot disagree with what is
//! there. `place` shapes each name to measure it and writes where the tab sits
//! onto the file it names; `draw` only paints; and turning a press into the tab
//! it landed on is `Model.resolve`'s, from those rects.

const std = @import("std");


const glyph_atlas = @import("../glyph_atlas.zig");
const Model = @import("../model.zig").Model;
const LineLayout = glyph_atlas.LineLayout;

const painter_mod = @import("../painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const drawLine = @import("../text.zig").draw;
const advance = @import("../text.zig").advance;

/// Below the finder's 3 and above, and never over a file: the bar has the
/// top strip to itself. The ground and the rule under it do not overlap, so they
/// share a layer; the tab in front covers both and needs one of its own.
/// The strip is recessed so that a tab lifted out of it reads as lifted. Against
/// the panel colour it did not: three parts in a hundred is not a difference
/// anyone can see.
const ground_key: Key = .{ .layer = 0, .pipeline = .solid, .colour = .chip };
const rule_key: Key = .{ .layer = 0, .pipeline = .solid, .colour = .edge };
const shown_key: Key = .{ .layer = 1, .pipeline = .solid, .colour = .background };
const seam_key: Key = .{ .layer = 2, .pipeline = .solid, .colour = .edge };
const name_key: Key = .{ .layer = 3, .pipeline = .glyphs, .colour = .text };
const other_key: Key = .{ .layer = 3, .pipeline = .glyphs, .colour = .muted };

/// In points, scaled like the font: the air either side of a tab, above and
/// below the name, and between the mark and the name.
///
/// Tight, because a bar of names is scanned rather than read. What keeps two
/// names apart at this spacing is the seam between their tabs rather than the
/// space, which is why the seam is here at all.
const across = 4;
const down = 4;
const beside = 3;

/// What says a file has been changed and not saved. One glyph, shaped once and
/// set down again for every tab that needs it -- a round mark, which a quad
/// cannot be.
const unsaved_mark = "\u{2022}";

/// Where a glyph's ink sits inside its advance: how far past the pen it starts,
/// and how wide it actually is.
const Ink = struct {
    from: f32 = 0,
    wide: f32 = 0,
};

pub const Tabs = struct {
    pub fn deinit(_: *Tabs, _: std.mem.Allocator) void {}

    /// Nothing at all when no file has been named: a strip with no tabs on it
    /// is a promise of something that is not there.
    pub fn height(_: *const Tabs, model: *const Model) ?f32 {
        if (listed(model) == 0) return 0;
        return @round(model.atlas.line_height + 2 * @round(down * model.atlas.scale));
    }

    /// Lays the bar out: shapes the mark and every name, works out where each
    /// tab sits, and writes the band onto the model and each tab's rect onto the
    /// file it names. Drawing then only reads, and a press -- which comes after a
    /// frame -- has rects to hit. The mark's width is reserved on both sides of
    /// every name, so a file being typed into does not shift the bar and its name
    /// sits centred rather than hard against the right edge.
    pub fn place(_: *Tabs, model: *Model, rect: Rect) !void {
        model.tabs_rect = rect;
        if (listed(model) == 0) return;

        if (model.atlas.stale(&model.tab_bullet)) try model.atlas.shapeLine(unsaved_mark, &model.tab_bullet);
        const ink = inkOf(&model.tab_bullet);

        const inset = @round(across * model.atlas.scale);
        const gap = @round(beside * model.atlas.scale);

        var left = rect.x;
        for (model.files.items) |file| {
            const path = file.path orelse continue;

            // A scratch preview leans, so a tab that will be replaced by the
            // next file opened reads as the loan it is. Reshaped when the slant
            // has to change as well as when the atlas has, since the generation
            // is the same either way and cannot say the style went stale.
            const preview = model.preview == file;
            if (model.atlas.stale(&file.name) or file.name.slanted != preview) {
                const basename = std.fs.path.basename(path);
                if (preview)
                    try model.atlas.shapeSlanted(basename, &file.name)
                else
                    try model.atlas.shapeLine(basename, &file.name);
            }

            const width = @round(advance(&file.name) + 2 * (ink.wide + gap) + 2 * inset);
            file.tab_rect = .{ .x = left, .y = rect.y, .width = width, .height = rect.height };
            left += width;
        }
    }

    pub fn draw(_: *Tabs, model: *const Model, painter: *Painter) !void {
        if (listed(model) == 0) return;

        const bar = model.tabs_rect;
        const line = @max(1, @round(model.atlas.scale));
        const inset = @round(across * model.atlas.scale);
        const gap = @round(beside * model.atlas.scale);
        const ink = inkOf(&model.tab_bullet);

        // The strip, and the rule that closes it off. Cut so they do not
        // overlap, which is what lets them share a layer.
        try painter.add(ground_key, .solid(
            .{ bar.x, bar.y },
            .{ bar.width, @max(0, bar.height - line) },
        ));
        try painter.add(rule_key, .solid(
            .{ bar.x, bar.y + bar.height - line },
            .{ bar.width, line },
        ));

        for (model.files.items) |file| {
            if (file.path == null) continue;
            const r = file.tab_rect;

            // The one in front is the colour of the page. It stops short of the
            // rule along the bottom rather than covering it, so the bar's edge
            // runs unbroken under every tab.
            // Two signals, because there are two questions and with the window
            // split they have different answers: the ground says whether the
            // file is on screen at all, and the name's colour says whether it is
            // the one being typed into.
            if (model.onScreen(file)) try painter.add(shown_key, .solid(
                .{ r.x, bar.y },
                .{ r.width, @max(0, bar.height - line) },
            ));

            // Down the right edge of every tab, over the fill rather than under
            // it, so the one in front is edged on both sides like the rest.
            try painter.add(seam_key, .solid(
                .{ r.x + r.width - line, bar.y },
                .{ line, @max(0, bar.height - line) },
            ));

            const key = if (model.showing() == file) name_key else other_key;
            const baseline = @round(bar.y + @round(down * model.atlas.scale) + model.atlas.ascent);

            // The mark's room is taken whether or not it is drawn, placed by its
            // ink rather than its pen so what was reserved is what appears there.
            if (file.modified) {
                try drawLine(painter, key, &model.tab_bullet, .{ @round(r.x + inset - ink.from), baseline });
            }
            try drawLine(painter, key, &file.name, .{ @round(r.x + inset + ink.wide + gap), baseline });
        }
    }

    /// What the mark draws, not what it advances. A bullet carries wide side
    /// bearings, and reserving them twice over would be paying for space
    /// `beside` is already providing -- on a bar this tight, twice.
    fn inkOf(bullet: *const LineLayout) Ink {
        if (bullet.sprites.items.len == 0) return .{};
        return .{ .from = bullet.sprites.items[0].dest[0], .wide = bullet.sprites.items[0].size[0] };
    }

    /// How many files have a name, which is how many tabs there are: a file
    /// nobody named has nothing to write on one, and a window showing one has
    /// no bar at all.
    fn listed(model: *const Model) usize {
        var count: usize = 0;
        for (model.files.items) |file| {
            if (file.path != null) count += 1;
        }
        return count;
    }
};
