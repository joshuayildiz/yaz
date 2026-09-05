//! The file finder: cmd+P, type, arrow keys, return.
//!
//! It does no listing or matching of its own: the model holds an index of the
//! tree and a search is a function call (see fff.zig). The panel is a `VTuple`
//! of two surfaces -- the query line and the matches -- laid over the file, each
//! carrying its own ground and edge so the file stays at full contrast either
//! side of it. Nothing is offered until something is typed.

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

/// Above the views and the tab bar, since the panel hangs over them. Each covers
/// the one before, so they are separate layers, not an order within one.
const edge_key: Key = .{ .layer = 4, .pipeline = .solid, .colour = .edge };
const surface_key: Key = .{ .layer = 5, .pipeline = .solid, .colour = .panel };
const chosen_key: Key = .{ .layer = 6, .pipeline = .solid, .colour = .selection };
const caret_key: Key = .{ .layer = 7, .pipeline = .solid, .colour = .caret };

/// The colour of a row's words is what says whether it is the chosen one, so it
/// is a key rather than an argument.
const text_key: Key = .{ .layer = 8, .pipeline = .glyphs, .colour = .text };
const muted_key: Key = .{ .layer = 8, .pipeline = .glyphs, .colour = .muted };
const faint_key: Key = .{ .layer = 8, .pipeline = .glyphs, .colour = .faint };

const column_share = 0.46;
const drop = 20;
const pad = 9;
const split = 8;
const leading = 1.45;

fn hairline(atlas: *const GlyphAtlas) f32 {
    return @max(1, @round(atlas.scale));
}

/// An edge with a ground inset inside it -- two quads, which cannot go out of
/// square the way four sides could.
fn surface(painter: *Painter, atlas: *const GlyphAtlas, rect: Rect) !void {
    const line = hairline(atlas);
    try painter.add(edge_key, .solid(.{ rect.x, rect.y }, .{ rect.width, rect.height }));
    try painter.add(surface_key, .solid(
        .{ rect.x + line, rect.y + line },
        .{ @max(0, rect.width - 2 * line), @max(0, rect.height - 2 * line) },
    ));
}

/// The line being typed, and how many of how many it matched. Keeps the glyphs
/// and nothing else: what was typed and found are the model's.
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

    /// A line of text with its padding, plus the gap to the list. Here rather
    /// than on the panel, which cannot know this is a line of text.
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

        // The typed length is what says the glyphs are stale, since `shapeLine`
        // marks its own work done and nothing else clears it.
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
            // Nothing typed, or everything matched: the total on its own.
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

/// The filename flush left, its directory flush right -- the name is what is
/// being chosen, so it gets the strong colour.
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

    /// The memoisation key: which set of matches `rows` was shaped from (a search
    /// answers with a new set each time), how many, and the atlas generation.
    /// Checked before shaping, rather than each row's own stamp.
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

            // The directory is on the row so two files of the same name are told
            // apart by what is in front of them.
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

            // Edge to edge inside the border, so the tint reads as the row and
            // not another box.
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

    /// A column down the middle, hanging a short way from the top; as tall as the
    /// two surfaces ask for, since neither takes what is left over.
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

        try self.panel.draw(model, painter);
    }
};
