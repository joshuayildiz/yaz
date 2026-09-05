//! The acme view: columns of stacked file windows, each window a tag line over a
//! text body, each column under a header with a `New` button. It reads
//! `model.acme` and draws it; the body rects it leaves on the files are how
//! `Model.resolve` finds a window, and `button` turns a press into a tag command.

const std = @import("std");

const Model = @import("../model.zig").Model;

const message_mod = @import("../message.zig");
const Message = message_mod.Message;

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

/// Air above and below a tag's text, in points scaled like the font.
const tag_pad = 4;

/// The unsaved mark, on the tag of a file with unwritten changes.
const unsaved_mark = "\u{2022}";

/// The tag labels, shaped into `model.acme_tags`.
const new_label = 0;
const del_label = 1;

pub const Columns = struct {
    pub fn deinit(_: *Columns, _: std.mem.Allocator) void {}

    /// Divides the room into equal columns, each a header over equal windows;
    /// each window is a tag line over a body. The body rect is written onto the
    /// file so `Model.resolve` and `TextView` can reach it. Names, the mark and
    /// the tag labels are shaped here so drawing and hit-testing only read.
    pub fn place(_: *Columns, model: *Model, rect: Rect) !void {
        const cols = model.acme.items;
        if (cols.len == 0) return;

        if (model.atlas.stale(&model.tab_bullet)) try model.atlas.shapeLine(unsaved_mark, &model.tab_bullet);
        if (model.atlas.stale(&model.acme_tags[new_label])) try model.atlas.shapeLine("New", &model.acme_tags[new_label]);
        if (model.atlas.stale(&model.acme_tags[del_label])) try model.atlas.shapeLine("Del", &model.acme_tags[del_label]);

        const tag = tagHeight(model);
        var x = rect.x;
        for (cols, 1..) |*col, nth| {
            const right = @round(rect.x + rect.width * @as(f32, @floatFromInt(nth)) / @as(f32, @floatFromInt(cols.len)));
            col.rect = .{ .x = x, .y = rect.y, .width = right - x, .height = rect.height };
            x = right;

            const panes = col.panes.items;
            const body_top = col.rect.y + tag; // below the column header
            var top = body_top;
            for (panes, 1..) |file, pnth| {
                const bottom = @round(body_top + (col.rect.height - tag) * @as(f32, @floatFromInt(pnth)) / @as(f32, @floatFromInt(panes.len)));
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
        const baseline_in = inset + model.atlas.ascent;

        for (model.acme.items) |*col| {
            try painter.add(rule_key, .solid(
                .{ col.rect.x + col.rect.width - line, col.rect.y },
                .{ line, col.rect.height },
            ));

            // The column header: its own strip, with `New` in it.
            try painter.add(tag_ground, .solid(
                .{ col.rect.x, col.rect.y },
                .{ col.rect.width, @max(0, tag - line) },
            ));
            try painter.add(rule_key, .solid(
                .{ col.rect.x, col.rect.y + tag - line },
                .{ col.rect.width, line },
            ));
            try drawLine(painter, other_key, &model.acme_tags[new_label], .{
                @round(col.rect.x + inset),
                @round(col.rect.y + baseline_in),
            });

            for (col.panes.items) |file| {
                const body = file.rect;
                const ty = body.y - tag;

                // The focused window's tag is the colour of the page and its name
                // is dark; the rest sit in the strip and read grey.
                const focused = model.showing() == file;
                try painter.add(if (focused) shown_ground else tag_ground, .solid(
                    .{ body.x, ty },
                    .{ body.width, @max(0, tag - line) },
                ));
                try painter.add(rule_key, .solid(
                    .{ body.x, ty + tag - line },
                    .{ body.width, line },
                ));

                const key = if (focused) name_key else other_key;
                const baseline = @round(ty + baseline_in);
                var left = body.x + inset;
                if (file.modified) {
                    try drawLine(painter, key, &model.tab_bullet, .{ @round(left), baseline });
                    left += advance(&model.tab_bullet) + inset;
                }
                try drawLine(painter, key, &file.name, .{ @round(left), baseline });

                // `Del` at the far end of the tag.
                try drawLine(painter, other_key, &model.acme_tags[del_label], .{
                    @round(body.x + body.width - advance(&model.acme_tags[del_label]) - inset),
                    baseline,
                });

                var view: TextView = .init(0, file, body);
                try view.draw(model, painter);
            }
        }
    }

    /// The tag command a press falls on -- `New` in a column header, `Del` at the
    /// end of a window tag -- or none when it falls on neither.
    pub fn button(model: *const Model, at: [2]f32) ?Message {
        const tag = tagHeight(model);
        const inset = @round(tag_pad * model.atlas.scale);

        var which: usize = 0;
        for (model.acme.items, 0..) |*col, i| {
            const new_w = advance(&model.acme_tags[new_label]) + 2 * inset;
            const new_box: Rect = .{ .x = col.rect.x, .y = col.rect.y, .width = new_w, .height = tag };
            if (new_box.contains(at)) return .{ .acme_new = i };

            for (col.panes.items) |file| {
                defer which += 1;
                const del_w = advance(&model.acme_tags[del_label]) + 2 * inset;
                const del_box: Rect = .{
                    .x = file.rect.x + file.rect.width - del_w,
                    .y = file.rect.y - tag,
                    .width = del_w,
                    .height = tag,
                };
                if (del_box.contains(at)) return .{ .acme_del = which };
            }
        }
        return null;
    }

    fn tagHeight(model: *const Model) f32 {
        return @round(model.atlas.line_height + 2 * @round(tag_pad * model.atlas.scale));
    }
};
