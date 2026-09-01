//! A tab per file open in this window, along the top.
//!
//! Each is as wide as the name in it, packed from the left, so the bar reads as
//! labels rather than as a grid: a row of equal shares is the wrong shape for a
//! row of words, which is why this lays its own tabs out.
//!
//! It owns nothing but the rects it drew them at. Which files exist, which are
//! on screen, which is being typed into and which have been changed are all
//! read off the model as it draws, so the bar cannot disagree with what is
//! there.
//!
//! A press answers `Change.show` and the tab's place on the bar, which is what
//! cmd+N means as well, so a tab reached either way says the same thing: show
//! this and put the rest away. Nothing here has to name a file to say it.

const std = @import("std");

const config = @import("../config.zig");
const message_mod = @import("../message.zig");
const Message = message_mod.Message;
const Change = message_mod.Change;

const glyph_atlas = @import("../glyph_atlas.zig");
const Model = @import("../model.zig").Model;
const OpenFile = @import("../open_file.zig").OpenFile;
const GlyphAtlas = glyph_atlas.GlyphAtlas;
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
const ground_key: Key = .{ .layer = 0, .pipeline = .solid, .colour = config.chip_colour };
const rule_key: Key = .{ .layer = 0, .pipeline = .solid, .colour = config.edge_colour };
const shown_key: Key = .{ .layer = 1, .pipeline = .solid, .colour = config.background };
const seam_key: Key = .{ .layer = 2, .pipeline = .solid, .colour = config.edge_colour };
const name_key: Key = .{ .layer = 3, .pipeline = .glyphs, .colour = config.text_colour };
const other_key: Key = .{ .layer = 3, .pipeline = .glyphs, .colour = config.muted_colour };

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
    /// The mark itself, shaped once. Its width is reserved on every tab whether
    /// it is drawn or not, so a file does not shift the bar by being typed into,
    /// and again on the other side of the name, so the name sits in the middle
    /// of the tab rather than hard against its right edge.
    bullet: LineLayout = .{},

    /// Where each one ended up, worked out while drawing, which is the only
    /// time the labels can be measured. A press comes after a frame, so there
    /// is always something to hit.
    rects: std.ArrayList(Rect) = .empty,

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(self: *Tabs, allocator: std.mem.Allocator) void {
        self.rects.deinit(allocator);
        self.bullet.deinit(allocator);
    }

    /// Nothing at all when no file has been named: a strip with no tabs on it
    /// is a promise of something that is not there.
    pub fn height(_: *const Tabs, model: *const Model) ?f32 {
        if (listed(model) == 0) return 0;
        return @round(model.atlas.line_height + 2 * @round(down * model.atlas.scale));
    }

    pub fn place(self: *Tabs, _: *const Model, rect: Rect) void {
        self.rect = rect;
    }

    pub fn update(self: *Tabs, _: *const Model, message: Message) !Change {
        const at = switch (message) {
            // A tab is chosen by where the press landed; shift means nothing
            // to a bar.
            .press => |what| what.at,
            else => return .none,
        };

        for (self.rects.items, 0..) |rect, which| {
            if (!rect.contains(at)) continue;
            // Pressing a tab is choosing that file over the others, which is
            // what cmd+N means too, and it is named the same way: by where it
            // sits on the bar.
            return .{ .show = which };
        }
        return .none;
    }

    pub fn draw(self: *Tabs, model: *const Model, painter: *Painter) !void {
        const count = listed(model);
        if (count == 0) return;

        // One per tab, sized here rather than as files are opened: the bar is
        // told nothing when one is.
        try self.rects.resize(model.allocator, count);

        const line = @max(1, @round(model.atlas.scale));
        const inset = @round(across * model.atlas.scale);
        const gap = @round(beside * model.atlas.scale);

        if (model.atlas.stale(&self.bullet)) try model.atlas.shapeLine(unsaved_mark, &self.bullet);

        // What the mark draws, not what it advances. A bullet carries wide side
        // bearings, and reserving them twice over would be paying for space
        // `beside` is already providing -- on a bar this tight, twice.
        const ink: Ink = if (self.bullet.sprites.items.len == 0) .{} else .{
            .from = self.bullet.sprites.items[0].dest[0],
            .wide = self.bullet.sprites.items[0].size[0],
        };

        // The strip, and the rule that closes it off. Cut so they do not
        // overlap, which is what lets them share a layer.
        try painter.add(ground_key, .solid(
            .{ self.rect.x, self.rect.y },
            .{ self.rect.width, @max(0, self.rect.height - line) },
        ));
        try painter.add(rule_key, .solid(
            .{ self.rect.x, self.rect.y + self.rect.height - line },
            .{ self.rect.width, line },
        ));

        var left = self.rect.x;
        var which: usize = 0;
        for (model.files.items) |file| {
            const path = file.path orelse continue;
            defer which += 1;

            const name = &file.name;
            if (model.atlas.stale(name)) try model.atlas.shapeLine(std.fs.path.basename(path), name);

            const width = @round(advance(name) + 2 * (ink.wide + gap) + 2 * inset);
            self.rects.items[which] = .{
                .x = left,
                .y = self.rect.y,
                .width = width,
                .height = self.rect.height,
            };

            // The one in front is the colour of the page. It stops short of the
            // rule along the bottom rather than covering it, so the bar's edge
            // runs unbroken under every tab.
            // Two signals, because there are two questions and with the window
            // split they have different answers: the ground says whether the
            // file is on screen at all, and the name's colour says whether it is
            // the one being typed into.
            const on_screen = model.onScreen(file);
            if (on_screen) try painter.add(shown_key, .solid(
                .{ left, self.rect.y },
                .{ width, @max(0, self.rect.height - line) },
            ));

            // Down the right edge of every tab, over the fill rather than under
            // it, so the one in front is edged on both sides like the rest.
            try painter.add(seam_key, .solid(
                .{ left + width - line, self.rect.y },
                .{ line, @max(0, self.rect.height - line) },
            ));

            const key = if (model.showing() == file) name_key else other_key;
            const baseline = @round(self.rect.y + @round(down * model.atlas.scale) + model.atlas.ascent);

            // The mark's room is taken whether or not it is drawn, so a file
            // being typed into does not push the rest of the bar along; the
            // same room again on the right is what centres the name.
            if (file.modified) {
                // Placed by its ink rather than by its pen, so what was
                // reserved is what appears there.
                try drawLine(painter, key, &self.bullet, .{ @round(left + inset - ink.from), baseline });
            }
            try drawLine(painter, key, name, .{ @round(left + inset + ink.wide + gap), baseline });

            left += width;
        }
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
