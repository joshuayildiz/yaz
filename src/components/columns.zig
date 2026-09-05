//! The acme view: columns of stacked file windows, each window a tag line over a
//! text body. It reads `model.acme` (which file is in which column) and draws it;
//! the body rects it leaves on the files are how `Model.resolve` finds a window.

const std = @import("std");

const Model = @import("../model.zig").Model;

const painter_mod = @import("../painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const drawLine = @import("../text.zig").draw;
const advance = @import("../text.zig").advance;
const TextView = @import("./text_view.zig").TextView;

const tag_ground: Key = .{ .layer = 0, .pipeline = .solid, .colour = .chip };
const shown_ground: Key = .{ .layer = 0, .pipeline = .solid, .colour = .background };
const rule_key: Key = .{ .layer = 1, .pipeline = .solid, .colour = .edge };
const name_key: Key = .{ .layer = 2, .pipeline = .glyphs, .colour = .text };
const other_key: Key = .{ .layer = 2, .pipeline = .glyphs, .colour = .muted };

/// Air above and below a tag's name, in points scaled like the font.
const tag_pad = 4;

/// The unsaved mark, on the tag of a file with unwritten changes.
const unsaved_mark = "\u{2022}";

pub const Columns = struct {
    pub fn deinit(_: *Columns, _: std.mem.Allocator) void {}

    /// Divides the room into equal columns, each into equal windows; each window
    /// is a tag line over a body, and the body rect is written onto the file so
    /// `Model.resolve` and `TextView` can reach it. Names and the mark are shaped
    /// here so drawing only reads.
    pub fn place(_: *Columns, model: *Model, rect: Rect) !void {
        const cols = model.acme.items;
        if (cols.len == 0) return;

        if (model.atlas.stale(&model.tab_bullet)) try model.atlas.shapeLine(unsaved_mark, &model.tab_bullet);
        const tag = tagHeight(model);

        var x = rect.x;
        for (cols, 1..) |*col, nth| {
            const right = @round(rect.x + rect.width * @as(f32, @floatFromInt(nth)) / @as(f32, @floatFromInt(cols.len)));
            col.rect = .{ .x = x, .y = rect.y, .width = right - x, .height = rect.height };
            x = right;

            const panes = col.panes.items;
            var top = col.rect.y;
            for (panes, 1..) |file, pnth| {
                const bottom = @round(col.rect.y + col.rect.height * @as(f32, @floatFromInt(pnth)) / @as(f32, @floatFromInt(panes.len)));
                file.rect = .{
                    .x = col.rect.x,
                    .y = top + tag,
                    .width = col.rect.width,
                    .height = @max(0, bottom - top - tag),
                };
                top = bottom;

                const preview = model.preview == file;
                if (model.atlas.stale(&file.name) or file.name.slanted != preview) {
                    const basename = std.fs.path.basename(file.path orelse "");
                    if (preview)
                        try model.atlas.shapeSlanted(basename, &file.name)
                    else
                        try model.atlas.shapeLine(basename, &file.name);
                }

                var view: TextView = .init(0, file, file.rect);
                view.settle(model);
            }
        }
    }

    pub fn draw(_: *Columns, model: *const Model, painter: *Painter) !void {
        const line = @max(1, @round(model.atlas.scale));
        const tag = tagHeight(model);
        const inset = @round(tag_pad * model.atlas.scale);

        for (model.acme.items) |*col| {
            // A rule down the right edge of every column but the last.
            try painter.add(rule_key, .solid(
                .{ col.rect.x + col.rect.width - line, col.rect.y },
                .{ line, col.rect.height },
            ));

            for (col.panes.items) |file| {
                const body = file.rect;
                const tag_rect: Rect = .{ .x = body.x, .y = body.y - tag, .width = body.width, .height = tag };

                // The focused window's tag is the colour of the page and its name
                // is dark; the rest sit in the recessed strip and read grey.
                const focused = model.showing() == file;
                try painter.add(if (focused) shown_ground else tag_ground, .solid(
                    .{ tag_rect.x, tag_rect.y },
                    .{ tag_rect.width, @max(0, tag_rect.height - line) },
                ));
                try painter.add(rule_key, .solid(
                    .{ tag_rect.x, tag_rect.y + tag_rect.height - line },
                    .{ tag_rect.width, line },
                ));

                const key = if (focused) name_key else other_key;
                const baseline = @round(tag_rect.y + inset + model.atlas.ascent);
                var left = tag_rect.x + inset;
                if (file.modified) {
                    try drawLine(painter, key, &model.tab_bullet, .{ @round(left), baseline });
                    left += advance(&model.tab_bullet) + inset;
                }
                try drawLine(painter, key, &file.name, .{ @round(left), baseline });

                var view: TextView = .init(0, file, body);
                try view.draw(model, painter);
            }
        }
    }

    fn tagHeight(model: *const Model) f32 {
        return @round(model.atlas.line_height + 2 * @round(tag_pad * model.atlas.scale));
    }
};
