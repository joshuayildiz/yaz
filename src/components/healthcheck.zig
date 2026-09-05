//! What the window shows when yaz cannot run.
//!
//! The library the finder is built on is not optional, so a startup that cannot
//! load it puts this up instead of an editor and turns everything else off. It
//! says what is missing, where it was looked for, and what to type.
//!
//! It never changes while it is up: the check runs once, at startup, so
//! installing in another terminal means starting yaz again.

const std = @import("std");

const config = @import("../config.zig");

const glyph_atlas = @import("../glyph_atlas.zig");
const Model = @import("../model.zig").Model;
const LineLayout = glyph_atlas.LineLayout;

const painter_mod = @import("../painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const drawLine = @import("../text.zig").draw;
const advance = @import("../text.zig").advance;

const tools = @import("../tools.zig");

/// Card behind, accent and chip on it, text over both; nothing within a layer
/// overlaps.
const card_key: Key = .{ .layer = 0, .pipeline = .solid, .colour = .panel };
const accent_key: Key = .{ .layer = 1, .pipeline = .solid, .colour = .bad };
const chip_key: Key = .{ .layer = 1, .pipeline = .solid, .colour = .chip };
const text_layer = 2;

const pad = 36;
const gap = 14;
const chip_pad = 8;

/// The one strong mark on the card, down the left of the heading.
const accent = 3;

/// A run of text placed on its own -- pieces rather than lines because a
/// proportional font's columns can only be lined up by measuring what is in them.
const Piece = struct {
    text: []u8,
    colour: config.Colour,
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

/// One tool's row: its name, whether it runs, and where it was looked for.
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
                .name = try piece(allocator, tool.title(), .text),
                .status = try piece(
                    allocator,
                    if (absent) "not installed" else "ready",
                    if (absent) .bad else .good,
                ),
                .where = .{ .text = where, .colour = .muted },
            };
            made += 1;
        }

        return .{
            .heading = try piece(allocator, "yaz can't start", .text),
            .rows = rows,
            .run = try piece(allocator, "Run", .muted),
            .command = try piece(allocator, "yaz setup", .text),
            .tail = try piece(allocator, "and start yaz again.", .muted),
        };
    }

    fn piece(allocator: std.mem.Allocator, text: []const u8, colour: config.Colour) !Piece {
        return .{ .text = try allocator.dupe(u8, text), .colour = colour };
    }

    pub fn deinit(self: *Healthcheck, allocator: std.mem.Allocator) void {
        self.heading.deinit(allocator);
        for (&self.rows) |*row| {
            row.name.deinit(allocator);
            row.status.deinit(allocator);
            row.where.deinit(allocator);
        }
        self.run.deinit(allocator);
        self.command.deinit(allocator);
        self.tail.deinit(allocator);
    }

    pub fn place(self: *Healthcheck, model: *Model, rect: Rect) !void {
        _ = model.atlas;
        self.rect = rect;
    }

    const piece_count = 4 + tools.Tool.all.len * 3;

    /// Every piece there is, so shaping and dropping cannot disagree.
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

    /// Rows of the card, blanks included as spacing, so the rhythm stays a
    /// multiple of the line height whatever the font size.
    const heading_row = 0;
    const first_tool_row = 2;
    const footer_row = first_tool_row + tools.Tool.all.len + 1;
    const row_count = footer_row + 1;

    pub fn draw(self: *Healthcheck, model: *const Model, painter: *Painter) !void {
        painter.clipTo(self.rect);
        defer painter.clipTo(null);

        // Shaped before placing: the columns line up from measured widths, and
        // nothing can be measured until it is shaped.
        var all: [piece_count]*Piece = undefined;
        self.pieces(&all);
        for (all) |target| {
            if (model.atlas.stale(&target.layout)) try model.atlas.shapeLine(target.text, &target.layout);
        }

        const scale = model.atlas.scale;
        const step = model.atlas.line_height;
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
        // A little above the middle, which reads as centred; a box at the exact
        // middle reads low. Whole pixels, since the text is placed from here.
        const left = @round(self.rect.x + (self.rect.width - card.width) / 2);
        const top = @round(self.rect.y + (self.rect.height - card.height) * 0.42);

        try painter.add(card_key, .solid(.{ left, top }, .{ card.width, card.height }));

        const text_left = left + padding;
        const baseline = struct {
            fn at(t: f32, p: f32, s: f32, ascent: f32, row: f32) f32 {
                return @round(t + p + row * s + ascent);
            }
        }.at;

        const heading_y = baseline(top, padding, step, model.atlas.ascent, heading_row);
        try self.heading.draw(painter, .{ text_left, heading_y });

        // Beside the heading only, in the left padding rather than a gutter of
        // its own, so the card stays even on both sides. Down the whole card it
        // would read as a border, not a mark.
        const mark = @round(accent * scale);
        try painter.add(accent_key, .solid(
            .{ text_left - spacing - mark, @round(heading_y - model.atlas.ascent) },
            .{ mark, step },
        ));

        for (&self.rows, 0..) |*row, index| {
            const y = baseline(top, padding, step, model.atlas.ascent, @floatFromInt(first_tool_row + index));
            var x = text_left;
            try row.name.draw(painter, .{ x, y });
            x += name_column + spacing;
            try row.status.draw(painter, .{ x, y });
            x += status_column + spacing;
            try row.where.draw(painter, .{ x, y });
        }

        const footer_y = baseline(top, padding, step, model.atlas.ascent, footer_row);
        try self.run.draw(painter, .{ text_left, footer_y });

        const chip_x = text_left + self.run.width() + spacing;
        try painter.add(chip_key, .solid(
            .{ chip_x, @round(footer_y - model.atlas.ascent) },
            .{ chip_width, step },
        ));
        try self.command.draw(painter, .{ chip_x + @round(chip_pad * scale), footer_y });
        try self.tail.draw(painter, .{ chip_x + chip_width + spacing, footer_y });
    }
};
