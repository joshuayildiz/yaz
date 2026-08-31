//! The file finder: cmd+P, type, arrow keys, return.
//!
//! It does no listing and no matching of its own. `rg --files` says what there
//! is to choose between, honouring .gitignore, and `fzf --filter` ranks it
//! against what has been typed. Both are checked at startup, so by the time one
//! of these exists they are known to run.
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

const config = @import("../config.zig");
const message_mod = @import("../message.zig");
const Message = message_mod.Message;
const Intent = message_mod.Intent;

const glyph_atlas = @import("../glyph_atlas.zig");
const Model = @import("../model.zig").Model;
const GlyphAtlas = glyph_atlas.GlyphAtlas;
const LineLayout = glyph_atlas.LineLayout;

const painter_mod = @import("../painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const drawLine = @import("../text.zig").draw;
const advance = @import("../text.zig").advance;

const VTuple = @import("./vtuple.zig").VTuple;

const tools = @import("../tools.zig");

/// Above a view's 0, 1 and 2 and the tab bar's 0 to 3 -- the panel hangs from the
/// top of the window and overlaps the bar. Each of these covers the one before
/// it, so they are separate layers rather than an order of drawing: within a
/// layer the painter is free to reorder, and it does.
const edge_key: Key = .{ .layer = 4, .pipeline = .solid, .colour = config.edge_colour };
const surface_key: Key = .{ .layer = 5, .pipeline = .solid, .colour = config.panel_colour };
const chosen_key: Key = .{ .layer = 6, .pipeline = .solid, .colour = config.selection_colour };
const caret_key: Key = .{ .layer = 7, .pipeline = .solid, .colour = config.caret_colour };

/// Words, above all of it. Which of the three a row is set in is what says
/// whether it is the chosen one, so the colours are keys rather than an
/// argument.
const text_key: Key = .{ .layer = 8, .pipeline = .glyphs, .colour = config.text_colour };
const muted_key: Key = .{ .layer = 8, .pipeline = .glyphs, .colour = config.muted_colour };
const faint_key: Key = .{ .layer = 8, .pipeline = .glyphs, .colour = config.faint_colour };

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

/// The most results on screen at once.
const visible_rows = 12;

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
const Query = struct {
    typed: std.ArrayList(u8) = .empty,
    layout: LineLayout = .{},

    /// How many of how many, drawn flush right. Set by the finder after it
    /// ranks, because only it knows the numbers.
    shown: usize = 0,
    total: usize = 0,
    count: LineLayout = .{},

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(self: *Query, model: *Model) void {
        self.typed.deinit(model.allocator);
        self.layout.deinit(model.allocator);
        self.count.deinit(model.allocator);
    }

    /// One line of text and the air round it, plus the gap that separates this
    /// surface from the list. Stated here rather than by the panel because the
    /// panel cannot know that this is a line of text.
    pub fn height(self: *const Query, model: *Model) ?f32 {
        _ = self;
        return @round(model.atlas.line_height + 2 * @round(pad * model.atlas.scale) + @round(split * model.atlas.scale));
    }

    /// The box itself, which is shorter than the band by the gap below it.
    fn box(self: *const Query, model: *Model) Rect {
        return .{
            .x = self.rect.x,
            .y = self.rect.y,
            .width = self.rect.width,
            .height = @round(model.atlas.line_height + 2 * @round(pad * model.atlas.scale)),
        };
    }

    pub fn place(self: *Query, model: *Model, rect: Rect) void {
        _ = model.atlas;
        self.rect = rect;
    }

    pub fn invalidate(self: *Query) void {
        self.layout.shaped = false;
        self.count.shaped = false;
    }

    pub fn clear(self: *Query) void {
        self.typed.clearRetainingCapacity();
        self.shown = 0;
        self.total = 0;
        self.invalidate();
    }

    /// What the finder found, for the far end of the line.
    pub fn counted(self: *Query, model: *Model, shown: usize, total: usize) void {
        self.shown = shown;
        self.total = total;
        self.count.shaped = false;
        model.changed();
    }

    pub fn update(self: *Query, model: *Model, message: Message) !Intent {
        _ = model.atlas;
        switch (message) {
            .text => |what| try self.typed.appendSlice(model.allocator, what),
            .backspace => {
                if (self.typed.items.len == 0) return .nothing;
                // One byte at a time is wrong the moment the query is not
                // ASCII, and `Buffer.stepBack` is where that is already solved;
                // this is a query, not a file, and cannot reach it.
                self.typed.items.len -= 1;
            },
            else => return .nothing,
        }

        // `shapeLine` marks what it shaped as done and nothing else clears it,
        // so without this the query is drawn once -- empty, on the frame it
        // opened -- and every character typed after goes on the panel without
        // appearing on it.
        self.layout.shaped = false;
        model.changed();
        return .nothing;
    }

    pub fn draw(self: *Query, model: *Model, painter: *Painter) !void {
        const inset = @round(pad * model.atlas.scale);
        const field = self.box(model);
        try surface(painter, model.atlas, field);

        const left = field.x + inset;
        const right = field.x + field.width - inset;
        const baseline = @round(field.y + inset + model.atlas.ascent);

        if (!self.layout.shaped) try model.atlas.shapeLine(self.typed.items, &self.layout);
        try drawLine(painter, text_key, &self.layout, .{ left, baseline });

        try painter.add(caret_key, .solid(
            .{ @round(left + advance(&self.layout)), @round(baseline - model.atlas.ascent) },
            .{ hairline(model.atlas), model.atlas.line_height },
        ));

        if (!self.count.shaped) {
            var buffer: [32]u8 = undefined;
            // Nothing typed, or everything matched: the total on its own, which
            // is what there is to search rather than what was found.
            const label = if (self.typed.items.len == 0 or self.shown == self.total)
                try std.fmt.bufPrint(&buffer, "{d}", .{self.total})
            else
                try std.fmt.bufPrint(&buffer, "{d} of {d}", .{ self.shown, self.total });
            try model.atlas.shapeLine(label, &self.count);
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

/// What the query matched, in fzf's order.
const Results = struct {
    /// Borrowed from the finder, which owns the bytes they point into. Empty
    /// until something is typed.
    matches: []const []const u8 = &.{},

    selected: usize = 0,
    /// The first match on screen. Follows `selected` rather than leading it.
    top_row: usize = 0,

    rows: [visible_rows]Row = @splat(.{}),
    /// Whether `rows` describes the matches currently on screen.
    laid_out: bool = false,

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(self: *Results, model: *Model) void {
        for (&self.rows) |*row| row.deinit(model.allocator);
    }

    /// As many rows as there are, and nothing at all when there are none: an
    /// empty box under an empty query would be a promise of something that is
    /// not there.
    pub fn height(self: *const Results, model: *Model) ?f32 {
        const shown = @min(self.matches.len, visible_rows);
        if (shown == 0) return 0;
        const step = @round(model.atlas.line_height * leading);
        return @round(@as(f32, @floatFromInt(shown)) * step + 2 * @round(pad * model.atlas.scale));
    }

    pub fn place(self: *Results, model: *Model, rect: Rect) void {
        _ = model.atlas;
        self.rect = rect;
    }

    pub fn invalidate(self: *Results) void {
        self.laid_out = false;
    }

    /// Points at a new set of matches and goes back to the top of it.
    pub fn show(self: *Results, model: *Model, matches: []const []const u8) void {
        self.matches = matches;
        self.selected = 0;
        self.top_row = 0;
        self.laid_out = false;
        model.changed();
    }

    /// What return would open.
    pub fn chosen(self: *const Results) ?[]const u8 {
        if (self.selected >= self.matches.len) return null;
        return self.matches[self.selected];
    }

    pub fn update(self: *Results, model: *Model, message: Message) !Intent {
        _ = model.atlas;
        switch (message) {
            .up => if (self.selected > 0) {
                self.selected -= 1;
            },
            .down => if (self.selected + 1 < self.matches.len) {
                self.selected += 1;
            },
            else => return .nothing,
        }

        // Keep the selection on screen, without moving further than it has to.
        if (self.selected < self.top_row) self.top_row = self.selected;
        if (self.selected >= self.top_row + visible_rows) {
            self.top_row = self.selected + 1 - visible_rows;
        }
        self.laid_out = false;
        model.changed();
        return .nothing;
    }

    /// Shapes the rows on screen, and only those.
    fn layOut(self: *Results, atlas: *GlyphAtlas) !void {
        if (self.laid_out) return;

        for (&self.rows, 0..) |*row, index| {
            const which = self.top_row + index;
            if (which >= self.matches.len) {
                row.name.sprites.clearRetainingCapacity();
                row.directory.sprites.clearRetainingCapacity();
                continue;
            }

            const path = self.matches[which];
            try atlas.shapeLine(std.fs.path.basename(path), &row.name);

            // Everything up to the last separator, kept: two files of the same
            // name are told apart by what is in front of them, and that is the
            // whole reason the directory is on the row at all.
            try atlas.shapeLine(std.fs.path.dirname(path) orelse "", &row.directory);
        }
        self.laid_out = true;
    }

    pub fn draw(self: *Results, model: *Model, painter: *Painter) !void {
        if (self.matches.len == 0) return;
        try self.layOut(model.atlas);

        try surface(painter, model.atlas, self.rect);

        const line = hairline(model.atlas);
        const inset = @round(pad * model.atlas.scale);
        const step = @round(model.atlas.line_height * leading);
        const left = self.rect.x + inset;
        const right = self.rect.x + self.rect.width - inset;

        for (&self.rows, 0..) |*row, index| {
            const which = self.top_row + index;
            if (which >= self.matches.len) break;

            const is_chosen = which == self.selected;
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
    /// Resolved once. Both are known to run: startup refused to get this far
    /// otherwise.
    rg: []u8,
    fzf: []u8,

    showing: bool = false,

    /// `rg --files` verbatim, with `all` pointing into it. One allocation for
    /// the whole listing rather than one per path.
    listing: []u8 = &.{},
    all: std.ArrayList([]const u8) = .empty,

    /// `fzf --filter` verbatim, with `matches` pointing into it.
    ranked: []u8 = &.{},
    matches: std.ArrayList([]const u8) = .empty,

    panel: Panel,

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn init(allocator: std.mem.Allocator, environ: std.process.Environ) !Finder {
        const rg = try tools.path(allocator, environ, .rg);
        errdefer allocator.free(rg);
        const fzf = try tools.path(allocator, environ, .fzf);

        return .{
            .rg = rg,
            .fzf = fzf,
            .panel = .init(.{ .{}, .{} }),
        };
    }

    pub fn deinit(self: *Finder, model: *Model) void {
        self.close(model);
        self.all.deinit(model.allocator);
        self.matches.deinit(model.allocator);
        self.panel.deinit(model);

        model.allocator.free(self.rg);
        model.allocator.free(self.fzf);
    }

    /// Everything that only exists while it is open. The listing is the one
    /// thing here that grows with the repository, so it does not outlive a
    /// closed finder.
    fn close(self: *Finder, model: *Model) void {
        self.showing = false;

        // Before the bytes go, since the rows point into them.
        self.panel.get(Results).show(model, &.{});
        self.panel.get(Query).clear();

        self.all.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();

        model.allocator.free(self.listing);
        self.listing = &.{};
        model.allocator.free(self.ranked);
        self.ranked = &.{};
    }

    /// A measure down the middle, hanging a short way from the top of the
    /// window. Its height is whatever the two surfaces asked for, since neither
    /// of them wants what is left over.
    pub fn place(self: *Finder, model: *Model, rect: Rect) void {
        self.rect = rect;

        const column = @round(rect.width * column_share);
        const top = @round(rect.y + @round(drop * model.atlas.scale));
        self.panel.place(model, .{
            .x = @round(rect.x + (rect.width - column) / 2),
            .y = top,
            .width = column,
            .height = @max(0, rect.y + rect.height - top),
        });
    }

    pub fn invalidate(self: *Finder) void {
        self.panel.invalidate();
    }

    /// Reads what there is to choose between and shows the panel.
    pub fn show(self: *Finder, model: *Model) !void {
        self.close(model);
        self.showing = true;
        model.changed();

        const result = try std.process.run(model.allocator, model.io, .{
            .argv = &.{ self.rg, "--files" },
            .stdout_limit = .limited(16 << 20),
        });
        defer model.allocator.free(result.stderr);
        errdefer model.allocator.free(result.stdout);

        self.listing = result.stdout;
        var lines = std.mem.splitScalar(u8, self.listing, '\n');
        while (lines.next()) |line| {
            if (line.len != 0) try self.all.append(model.allocator, line);
        }

        try self.rank(model);
    }

    /// The path it answers with is copied out of the listing, which closing
    /// frees, so whoever takes it owns it.
    pub fn update(self: *Finder, model: *Model, message: Message) !Intent {
        switch (message) {
            .cancel, .find => {
                self.close(model);
                return .dismiss;
            },
            .newline => {
                const picked = self.panel.get(Results).chosen() orelse return .nothing;
                const path = try model.allocator.dupe(u8, picked);
                self.close(model);
                return .{ .open = path };
            },
            // The selection is the list's, and the characters are the query's.
            // Both are in the panel; only the arrows are not for the one with
            // the keyboard, so they are handed over by name.
            .up, .down => return self.panel.get(Results).update(model, message),
            .text, .backspace => {
                _ = try self.panel.update(model, message);
                try self.rank(model);
                return .nothing;
            },
            else => return .nothing,
        }
    }

    /// Re-ranks against the query. Nothing typed is nothing offered: the whole
    /// repository is not an answer, and shaping a screenful of it would be work
    /// done on the way to being thrown away.
    fn rank(self: *Finder, model: *Model) !void {
        self.matches.clearRetainingCapacity();
        self.panel.get(Results).show(model, &.{});

        model.allocator.free(self.ranked);
        self.ranked = &.{};

        const query = self.panel.get(Query).typed.items;
        if (query.len != 0) {
            const filter = try std.fmt.allocPrint(model.allocator, "--filter={s}", .{query});
            defer model.allocator.free(filter);

            var child = try std.process.spawn(model.io, .{
                .argv = &.{ self.fzf, filter },
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .ignore,
            });
            errdefer child.kill(model.io);

            // Everything in, then the pipe closed, then everything out. Safe in
            // that order because `--filter` has to score every candidate before
            // it can sort them, so it writes nothing until stdin ends --
            // measured at 8.6MB each way without wedging.
            {
                var buffer: [64 * 1024]u8 = undefined;
                var writer = child.stdin.?.writer(model.io, &buffer);
                try writer.interface.writeAll(self.listing);
                try writer.interface.flush();
            }
            child.stdin.?.close(model.io);
            child.stdin = null;

            var buffer: [64 * 1024]u8 = undefined;
            var reader = child.stdout.?.reader(model.io, &buffer);
            self.ranked = try reader.interface.allocRemaining(model.allocator, .limited(16 << 20));

            _ = try child.wait(model.io);

            var lines = std.mem.splitScalar(u8, self.ranked, '\n');
            while (lines.next()) |line| {
                if (line.len != 0) try self.matches.append(model.allocator, line);
            }
        }

        self.panel.get(Results).show(model, self.matches.items);
        self.panel.get(Query).counted(model, self.matches.items.len, self.all.items.len);
    }

    pub fn draw(self: *Finder, model: *Model, painter: *Painter) !void {
        if (!self.showing) return;

        painter.clipTo(self.rect);
        defer painter.clipTo(null);

        // Nothing is laid over the file: the panel is two opaque surfaces
        // and the code either side of them is not dimmed at all.
        try self.panel.draw(model, painter);
    }
};
