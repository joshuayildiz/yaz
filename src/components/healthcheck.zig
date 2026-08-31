//! What the window shows when yaz cannot run.
//!
//! ripgrep and fzf are not optional -- the finder is built on them -- so a
//! startup that cannot run both puts this up instead of an editor and turns
//! everything else off. It says which tool is missing, where it was looked for,
//! and what to type.
//!
//! It never changes while it is up: the probe runs once, at startup, so
//! installing the tools in another terminal means starting yaz again.

const std = @import("std");

const config = @import("../config.zig");
const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const Intent = event_mod.Intent;

const glyph_atlas = @import("../glyph_atlas.zig");
const Context = @import("../context.zig").Context;
const GlyphAtlas = glyph_atlas.GlyphAtlas;
const LineLayout = glyph_atlas.LineLayout;

const painter_mod = @import("../painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const drawLine = @import("../text.zig").draw;
const advance = @import("../text.zig").advance;

const tools = @import("../tools.zig");

/// The card is behind everything, the accent and the chip on it, the text on top
/// of both. Nothing within a layer overlaps.
const card_key: Key = .{ .layer = 0, .pipeline = .solid, .colour = config.panel_colour };
const accent_key: Key = .{ .layer = 1, .pipeline = .solid, .colour = config.bad_colour };
const chip_key: Key = .{ .layer = 1, .pipeline = .solid, .colour = config.chip_colour };
const text_layer = 2;

/// In points, scaled like the font. Multiples of a common step, so the spacing
/// reads as deliberate rather than as whatever fitted.
const pad = 36;
const gap = 14;
const chip_pad = 8;

/// The one strong mark on the card, in its own gutter down the left of the
/// heading. It is what a border, a rule and a dot per tool were doing between
/// them before.
const accent = 3;

/// A run of text placed on its own.
///
/// The view is pieces rather than lines because the font is proportional: a
/// column can only be lined up by measuring what is in it, and padding with
/// spaces comes out ragged.
const Piece = struct {
    text: []u8,
    colour: [4]f32,
    layout: LineLayout = .{},

    fn deinit(self: *Piece, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.layout.deinit(allocator);
    }

    fn width(self: *const Piece) f32 {
        return advance(&self.layout);
    }

    fn draw(self: *const Piece, painter: *Painter, at: [2]f32) !void {
        const key: Key = .{ .layer = text_layer, .pipeline = .glyphs, .colour = self.colour };
        try drawLine(painter, key, &self.layout, at);
    }
};

/// One tool across the row: its name, whether it runs, and where it was looked
/// for. The status is a word and a colour together, so neither is carrying it
/// alone and neither needs a mark of its own beside it.
const Row = struct {
    name: Piece,
    status: Piece,
    where: Piece,
};

pub const Healthcheck = struct {
    heading: Piece,
    rows: [tools.Tool.all.len]Row,

    /// The last line, in three pieces so the command can sit in a chip.
    run: Piece,
    command: Piece,
    tail: Piece,

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn init(
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
        missing: tools.Missing,
    ) !Healthcheck {
        var made: usize = 0;
        var rows: [tools.Tool.all.len]Row = undefined;
        errdefer for (rows[0..made]) |*row| {
            row.name.deinit(allocator);
            row.status.deinit(allocator);
            row.where.deinit(allocator);
        };

        for (tools.Tool.all, &rows) |tool, *row| {
            const absent = missing.has(tool);
            const where = try tools.path(allocator, environ, tool);
            errdefer allocator.free(where);

            row.* = .{
                .name = try piece(allocator, tool.title(), config.text_colour),
                .status = try piece(
                    allocator,
                    if (absent) "not installed" else "ready",
                    if (absent) config.bad_colour else config.good_colour,
                ),
                .where = .{ .text = where, .colour = config.muted_colour },
            };
            made += 1;
        }

        return .{
            .heading = try piece(allocator, "yaz can't start", config.text_colour),
            .rows = rows,
            .run = try piece(allocator, "Run", config.muted_colour),
            .command = try piece(allocator, "yaz setup", config.text_colour),
            .tail = try piece(allocator, "and start yaz again.", config.muted_colour),
        };
    }

    fn piece(allocator: std.mem.Allocator, text: []const u8, colour: [4]f32) !Piece {
        return .{ .text = try allocator.dupe(u8, text), .colour = colour };
    }

    pub fn deinit(self: *Healthcheck, cx: *Context) void {
        self.heading.deinit(cx.allocator);
        for (&self.rows) |*row| {
            row.name.deinit(cx.allocator);
            row.status.deinit(cx.allocator);
            row.where.deinit(cx.allocator);
        }
        self.run.deinit(cx.allocator);
        self.command.deinit(cx.allocator);
        self.tail.deinit(cx.allocator);
    }

    pub fn place(self: *Healthcheck, cx: *Context, rect: Rect) void {
        _ = cx.atlas;
        self.rect = rect;
    }

    /// Nothing here reacts to anything. Quit and resize belong to the window and
    /// have been dealt with above; every other event is for an editor that is
    /// not running.
    pub fn update(self: *Healthcheck, cx: *Context, event: Event) !Intent {
        _ = self;
        _ = event;
        _ = cx.atlas;
        return .nothing;
    }

    /// Every shaped piece goes, for after the atlas is rebuilt at a different
    /// scale, for the reason `OpenFile.invalidate` gives.
    pub fn invalidate(self: *Healthcheck) void {
        var all: [piece_count]*Piece = undefined;
        self.pieces(&all);
        for (all) |target| target.layout.shaped = false;
    }

    const piece_count = 4 + tools.Tool.all.len * 3;

    /// Every piece there is, so that shaping and dropping cannot disagree about
    /// what the view is made of.
    fn pieces(self: *Healthcheck, out: *[piece_count]*Piece) void {
        var at: usize = 0;
        out[at] = &self.heading;
        at += 1;
        for (&self.rows) |*row| {
            for ([_]*Piece{ &row.name, &row.status, &row.where }) |target| {
                out[at] = target;
                at += 1;
            }
        }
        for ([_]*Piece{ &self.run, &self.command, &self.tail }) |target| {
            out[at] = target;
            at += 1;
        }
        std.debug.assert(at == out.len);
    }

    /// Rows of the card, top to bottom. Blank ones are spacing, and are here
    /// rather than as pixel constants so the rhythm stays a multiple of the line
    /// height whatever the font size is.
    const heading_row = 0;
    const first_tool_row = 2;
    const footer_row = first_tool_row + tools.Tool.all.len + 1;
    const row_count = footer_row + 1;

    pub fn draw(self: *Healthcheck, cx: *Context, painter: *Painter) !void {
        painter.clipTo(self.rect);
        defer painter.clipTo(null);

        // Shaped before anything is placed: every column here is lined up from
        // measured widths, and nothing can be measured until it is shaped.
        var all: [piece_count]*Piece = undefined;
        self.pieces(&all);
        for (all) |target| {
            if (!target.layout.shaped) try cx.atlas.shapeLine(target.text, &target.layout);
        }

        const scale = cx.atlas.scale;
        const step = cx.atlas.line_height;
        const padding = @round(pad * scale);
        const spacing = @round(gap * scale);

        // The tool table's columns are as wide as their widest cell.
        var name_column: f32 = 0;
        var status_column: f32 = 0;
        for (&self.rows) |*row| {
            name_column = @max(name_column, row.name.width());
            status_column = @max(status_column, row.status.width());
        }

        const chip_width = self.command.width() + 2 * @round(chip_pad * scale);
        const footer_width = self.run.width() + spacing + chip_width + spacing + self.tail.width();

        var widest = @max(self.heading.width(), footer_width);
        for (&self.rows) |*row| {
            widest = @max(widest, name_column + spacing + status_column + spacing + row.where.width());
        }

        const card: Rect = .{
            .width = @round(widest + 2 * padding),
            .height = @round(@as(f32, row_count) * step + 2 * padding),
            .x = 0,
            .y = 0,
        };
        // Horizontally centred; vertically a little above it, because a box at
        // the exact middle of a window reads as sitting low.
        //
        // Whole pixels: the text inside is placed from here, and a fractional
        // origin would change which subpixel variant it uses.
        const left = @round(self.rect.x + (self.rect.width - card.width) / 2);
        const top = @round(self.rect.y + (self.rect.height - card.height) * 0.42);

        try painter.add(card_key, .solid(.{ left, top }, .{ card.width, card.height }));

        const text_left = left + padding;
        const baseline = struct {
            fn at(t: f32, p: f32, s: f32, ascent: f32, row: f32) f32 {
                return @round(t + p + row * s + ascent);
            }
        }.at;

        const heading_y = baseline(top, padding, step, cx.atlas.ascent, heading_row);
        try self.heading.draw(painter, .{ text_left, heading_y });

        // Beside the heading only, and as tall as it: down the whole card it
        // would be a border again rather than a mark.
        //
        // It hangs in the left padding rather than in a gutter of its own, so
        // that the words start where the padding says and the card stays even
        // on both sides.
        const mark = @round(accent * scale);
        try painter.add(accent_key, .solid(
            .{ text_left - spacing - mark, @round(heading_y - cx.atlas.ascent) },
            .{ mark, step },
        ));

        for (&self.rows, 0..) |*row, index| {
            const y = baseline(top, padding, step, cx.atlas.ascent, @floatFromInt(first_tool_row + index));
            var x = text_left;
            try row.name.draw(painter, .{ x, y });
            x += name_column + spacing;
            try row.status.draw(painter, .{ x, y });
            x += status_column + spacing;
            try row.where.draw(painter, .{ x, y });
        }

        const footer_y = baseline(top, padding, step, cx.atlas.ascent, footer_row);
        try self.run.draw(painter, .{ text_left, footer_y });

        const chip_x = text_left + self.run.width() + spacing;
        try painter.add(chip_key, .solid(
            .{ chip_x, @round(footer_y - cx.atlas.ascent) },
            .{ chip_width, step },
        ));
        try self.command.draw(painter, .{ chip_x + @round(chip_pad * scale), footer_y });
        try self.tail.draw(painter, .{ chip_x + chip_width + spacing, footer_y });
    }
};
