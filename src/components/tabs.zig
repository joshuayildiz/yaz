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

/// The ground and the rule under it are cut so they do not overlap, so they can
/// share a layer; the tab in front covers both and needs one of its own.
const ground_key: Key = .{ .layer = 0, .pipeline = .solid, .colour = .chip };
const rule_key: Key = .{ .layer = 0, .pipeline = .solid, .colour = .edge };
const shown_key: Key = .{ .layer = 1, .pipeline = .solid, .colour = .background };
const seam_key: Key = .{ .layer = 2, .pipeline = .solid, .colour = .edge };
const name_key: Key = .{ .layer = 3, .pipeline = .glyphs, .colour = .text };
const other_key: Key = .{ .layer = 3, .pipeline = .glyphs, .colour = .muted };

/// In points, scaled like the font: the air across a tab, above and below the
/// name, and between the mark and the name.
const across = 4;
const down = 4;
const beside = 3;

const unsaved_mark = "\u{2022}";

/// Where a glyph's ink sits inside its advance: how far past the pen it starts,
/// and how wide it is.
const Ink = struct {
    from: f32 = 0,
    wide: f32 = 0,
};

pub const Tabs = struct {
    pub fn deinit(_: *Tabs, _: std.mem.Allocator) void {}

    /// No bar at all until a file has a name.
    pub fn height(_: *const Tabs, model: *const Model) ?f32 {
        if (listed(model) == 0) return 0;
        return @round(model.atlas.line_height + 2 * @round(down * model.atlas.scale));
    }

    /// Shapes the mark and every name, works out where each tab sits, and writes
    /// the band onto the model and each tab's rect onto the file it names. The
    /// mark's width is reserved on both sides of every name, so a file being
    /// typed into does not shift the bar and its name stays centred.
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

            // A scratch preview leans. Reshaped on a change of slant as well as
            // of atlas, since the generation cannot say the style went stale.
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

            // Two signals, with different answers in a split: the ground says
            // whether the file is on screen, the name's colour whether it has
            // the keyboard. The ground stops short of the rule so the bar's edge
            // runs unbroken under every tab.
            if (model.onScreen(file)) try painter.add(shown_key, .solid(
                .{ r.x, bar.y },
                .{ r.width, @max(0, bar.height - line) },
            ));

            try painter.add(seam_key, .solid(
                .{ r.x + r.width - line, bar.y },
                .{ line, @max(0, bar.height - line) },
            ));

            const key = if (model.showing() == file) name_key else other_key;
            const baseline = @round(bar.y + @round(down * model.atlas.scale) + model.atlas.ascent);

            // Placed by its ink rather than its pen, so what was reserved for it
            // is what appears there.
            if (file.modified) {
                try drawLine(painter, key, &model.tab_bullet, .{ @round(r.x + inset - ink.from), baseline });
            }
            try drawLine(painter, key, &file.name, .{ @round(r.x + inset + ink.wide + gap), baseline });
        }
    }

    /// What the mark draws, not what it advances: a bullet's wide side bearings
    /// are already covered by `beside`, and would be paid for twice otherwise.
    fn inkOf(bullet: *const LineLayout) Ink {
        if (bullet.sprites.items.len == 0) return .{};
        return .{ .from = bullet.sprites.items[0].dest[0], .wide = bullet.sprites.items[0].size[0] };
    }

    /// How many files have a name, which is how many tabs there are.
    fn listed(model: *const Model) usize {
        var count: usize = 0;
        for (model.files.items) |file| {
            if (file.path != null) count += 1;
        }
        return count;
    }
};
