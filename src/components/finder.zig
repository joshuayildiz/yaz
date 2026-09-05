//! The file finder: cmd+P, type, arrow keys, return.
//!
//! It does no listing and no matching of its own, and nothing is spawned to do
//! it either. The model holds an index of the tree -- built at startup, kept
//! fresh by a watcher -- and a search against it is a function call. See
//! src/fff.zig.
//!
//! The panel is a `VTuple` of two surfaces: the line being typed, and what it
//! matched. Each says how tall it is -- the query is one line of text and its
//! padding, the list is as many rows as it has -- so an empty query is a single
//! box with nothing under it, and the panel is never larger than what is in it.
//!
//! It is laid over the file rather than replacing it, and nothing is dimmed:
//! the surfaces carry their own ground and their own edge, so the code either
//! side of them stays at full contrast.
//!
//! Nothing is offered until something is typed. A list of every file in the
//! repository is not an answer to a question nobody has asked yet, and drawing
//! one would be a screenful of shaping done on the way to being replaced.

const std = @import("std");

const glyph_atlas = @import("../glyph_atlas.zig");
const model_mod = @import("../model.zig");
const Model = model_mod.Model;
const visible_rows = model_mod.visible_matches;
const GlyphAtlas = glyph_atlas.GlyphAtlas;
const LineLayout = glyph_atlas.LineLayout;

const painter_mod = @import("../painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const drawLine = @import("../text.zig").draw;
const advance = @import("../text.zig").advance;

const VTuple = @import("./vtuple.zig").VTuple;

/// Above a view's 0, 1 and 2 and the tab bar's 0 to 3 -- the panel hangs from the
/// top of the window and overlaps the bar. Each of these covers the one before
/// it, so they are separate layers rather than an order of drawing: within a
/// layer the painter is free to reorder, and it does.
const edge_key: Key = .{ .layer = 4, .pipeline = .solid, .colour = .edge };
const surface_key: Key = .{ .layer = 5, .pipeline = .solid, .colour = .panel };
const chosen_key: Key = .{ .layer = 6, .pipeline = .solid, .colour = .selection };
const caret_key: Key = .{ .layer = 7, .pipeline = .solid, .colour = .caret };

/// Words, above all of it. Which of the three a row is set in is what says
/// whether it is the chosen one, so the colours are keys rather than an
/// argument.
const text_key: Key = .{ .layer = 8, .pipeline = .glyphs, .colour = .text };
const muted_key: Key = .{ .layer = 8, .pipeline = .glyphs, .colour = .muted };
const faint_key: Key = .{ .layer = 8, .pipeline = .glyphs, .colour = .faint };

/// How wide the panel is, as a share of the window.
const column_share = 0.46;

/// In points, scaled like the font: how far the panel hangs from the top of the
/// window, the air inside a surface, and the gap that separates the two.
const drop = 20;
const pad = 9;
const split = 8;

/// Rows are set looser than body text. Air is most of what makes a list read as
/// set rather than dumped.
const leading = 1.45;

/// A hairline, whatever the display scale.
fn hairline(atlas: *const GlyphAtlas) f32 {
    return @max(1, @round(atlas.scale));
}

/// One floating surface: an edge, and a ground inset inside it. Two quads rather
/// than four sides, which is both fewer and impossible to get out of square.
fn surface(painter: *Painter, atlas: *const GlyphAtlas, rect: Rect) !void {
    const line = hairline(atlas);
    try painter.add(edge_key, .solid(.{ rect.x, rect.y }, .{ rect.width, rect.height }));
    try painter.add(surface_key, .solid(
        .{ rect.x + line, rect.y + line },
        .{ @max(0, rect.width - 2 * line), @max(0, rect.height - 2 * line) },
    ));
}

/// The line being typed, with what it matched said quietly at the far end of the
/// same measure, and a rule under both.
/// The line being typed, and how many of how many it matched.
///
/// It keeps the glyphs and nothing else: what was typed and what it found are
/// the model's, and this is what they look like.
const Query = struct {
    layout: LineLayout = .{},
    count: LineLayout = .{},

    /// What the layouts above were shaped from, so a frame that changed
    /// nothing shapes nothing.
    typed: usize = 0,
    shown: usize = 0,
    total: usize = 0,

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(self: *Query, allocator: std.mem.Allocator) void {
        self.layout.deinit(allocator);
        self.count.deinit(allocator);
    }

    /// One line of text and the air round it, plus the gap that separates this
    /// surface from the list. Stated here rather than by the panel because the
    /// panel cannot know that this is a line of text.
    pub fn height(_: *const Query, model: *const Model) ?f32 {
        return @round(model.atlas.line_height + 2 * @round(pad * model.atlas.scale) + @round(split * model.atlas.scale));
    }

    /// The box itself, which is shorter than the band by the gap below it.
    fn box(self: *const Query, model: *const Model) Rect {
        return .{
            .x = self.rect.x,
            .y = self.rect.y,
            .width = self.rect.width,
            .height = @round(model.atlas.line_height + 2 * @round(pad * model.atlas.scale)),
        };
    }

    pub fn place(self: *Query, _: *Model, rect: Rect) !void {
        self.rect = rect;
    }

    pub fn draw(self: *Query, model: *const Model, painter: *Painter) !void {
        const finding = &(model.finding orelse return);
        const inset = @round(pad * model.atlas.scale);
        const field = self.box(model);
        try surface(painter, model.atlas, field);

        const left = field.x + inset;
        const right = field.x + field.width - inset;
        const baseline = @round(field.y + inset + model.atlas.ascent);

        // `shapeLine` marks what it shaped as done and nothing else clears it,
        // so the length of what was typed is what says the glyphs are stale.
        if (model.atlas.stale(&self.layout) or self.typed != finding.typed.items.len) {
            try model.atlas.shapeLine(finding.typed.items, &self.layout);
            self.typed = finding.typed.items.len;
        }
        try drawLine(painter, text_key, &self.layout, .{ left, baseline });

        try painter.add(caret_key, .solid(
            .{ @round(left + advance(&self.layout)), @round(baseline - model.atlas.ascent) },
            .{ hairline(model.atlas), model.atlas.line_height },
        ));

        const shown = finding.count();
        const total = finding.files;
        if (model.atlas.stale(&self.count) or self.shown != shown or self.total != total) {
            var buffer: [32]u8 = undefined;
            // Nothing typed, or everything matched: the total on its own, which
            // is what there is to search rather than what was found.
            const label = if (finding.typed.items.len == 0 or shown == total)
                try std.fmt.bufPrint(&buffer, "{d}", .{total})
            else
                try std.fmt.bufPrint(&buffer, "{d} of {d}", .{ shown, total });
            try model.atlas.shapeLine(label, &self.count);
            self.shown = shown;
            self.total = total;
        }
        try drawLine(painter, faint_key, &self.count, .{ @round(right - advance(&self.count)), baseline });
    }
};

/// A row is set on two axes: the filename flush left, the directory it is in
/// flush right. The name is what is being chosen, so it gets the strong edge and
/// the strong colour.
const Row = struct {
    name: LineLayout = .{},
    directory: LineLayout = .{},

    fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        self.name.deinit(allocator);
        self.directory.deinit(allocator);
    }
};

/// What the query matched, best first.
const Results = struct {
    rows: [visible_rows]Row = @splat(.{}),

    /// Which set of matches `rows` was shaped from, and by which atlas. A
    /// search answers with a new set every time, so its identity and its length
    /// together say whether these glyphs are still the right ones -- and the
    /// generation says whether they are still the right size.
    ///
    /// The rows are `LineLayout`s and carry their own stamp, but nothing would
    /// look at it: this is the check that decides whether to shape them at all.
    listed: ?*anyopaque = null,
    count: usize = 0,
    top: usize = 0,
    stamp: u32 = 0,

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(self: *Results, allocator: std.mem.Allocator) void {
        for (&self.rows) |*row| row.deinit(allocator);
    }

    /// As many rows as there are, and nothing at all when there are none: an
    /// empty box under an empty query would be a promise of something that is
    /// not there.
    pub fn height(_: *const Results, model: *const Model) ?f32 {
        const finding = &(model.finding orelse return 0);
        const shown = @min(finding.count(), visible_rows);
        if (shown == 0) return 0;
        const step = @round(model.atlas.line_height * leading);
        return @round(@as(f32, @floatFromInt(shown)) * step + 2 * @round(pad * model.atlas.scale));
    }

    pub fn place(self: *Results, _: *Model, rect: Rect) !void {
        self.rect = rect;
    }

    /// Shapes the rows on screen, and only those.
    fn layOut(self: *Results, model: *const Model) !void {
        const finding = &(model.finding orelse return);
        const count = finding.count();
        if (self.listed == finding.token() and self.count == count and
            self.top == finding.top and self.stamp == model.atlas.generation) return;

        for (&self.rows, 0..) |*row, index| {
            const path = finding.path(finding.top + index) orelse {
                row.name.sprites.clearRetainingCapacity();
                row.directory.sprites.clearRetainingCapacity();
                continue;
            };

            try model.atlas.shapeLine(std.fs.path.basename(path), &row.name);

            // Everything up to the last separator, kept: two files of the same
            // name are told apart by what is in front of them, and that is the
            // whole reason the directory is on the row at all.
            try model.atlas.shapeLine(std.fs.path.dirname(path) orelse "", &row.directory);
        }

        self.listed = finding.token();
        self.count = count;
        self.top = finding.top;
        self.stamp = model.atlas.generation;
    }

    pub fn draw(self: *Results, model: *const Model, painter: *Painter) !void {
        const finding = &(model.finding orelse return);
        if (finding.count() == 0) return;
        try self.layOut(model);

        try surface(painter, model.atlas, self.rect);

        const line = hairline(model.atlas);
        const inset = @round(pad * model.atlas.scale);
        const step = @round(model.atlas.line_height * leading);
        const left = self.rect.x + inset;
        const right = self.rect.x + self.rect.width - inset;

        for (&self.rows, 0..) |*row, index| {
            const which = finding.top + index;
            if (which >= finding.count()) break;

            const is_chosen = which == finding.selected;
            const top = @round(self.rect.y + inset + @as(f32, @floatFromInt(index)) * step);
            const baseline = @round(top + (step - model.atlas.line_height) / 2 + model.atlas.ascent);

            // Edge to edge inside the border, so the tint reads as the row
            // rather than as another box inside the one it is already in.
            if (is_chosen) try painter.add(chosen_key, .solid(
                .{ self.rect.x + line, top },
                .{ @max(0, self.rect.width - 2 * line), step },
            ));

            try drawLine(painter, if (is_chosen) text_key else muted_key, &row.name, .{ left, baseline });
            try drawLine(painter, faint_key, &row.directory, .{
                @round(right - advance(&row.directory)),
                baseline,
            });
        }
    }
};

/// The panel: what is being typed, and what it matched.
const Panel = VTuple(&.{ Query, Results });

pub const Finder = struct {
    panel: Panel = .init(.{ .{}, .{} }),
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(self: *Finder, allocator: std.mem.Allocator) void {
        self.panel.deinit(allocator);
    }

    /// A measure down the middle, hanging a short way from the top of the
    /// window. Its height is whatever the two surfaces asked for, since neither
    /// of them wants what is left over.
    pub fn place(self: *Finder, model: *Model, rect: Rect) !void {
        self.rect = rect;

        const column = @round(rect.width * column_share);
        const top = @round(rect.y + @round(drop * model.atlas.scale));
        try self.panel.place(model, .{
            .x = @round(rect.x + (rect.width - column) / 2),
            .y = top,
            .width = column,
            .height = @max(0, rect.y + rect.height - top),
        });
    }

    pub fn draw(self: *Finder, model: *const Model, painter: *Painter) !void {
        if (model.finding == null) return;

        painter.clipTo(self.rect);
        defer painter.clipTo(null);

        // Nothing is laid over the file: the panel is two opaque surfaces and
        // the code either side of them is not dimmed at all.
        try self.panel.draw(model, painter);
    }
};
