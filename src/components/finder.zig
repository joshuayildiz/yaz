//! The file finder: cmd+P, type, arrow keys, return.
//!
//! It does no listing and no matching of its own. `rg --files` says what there
//! is to choose between, honouring .gitignore, and `fzf --filter` ranks it
//! against what has been typed. Both are checked at startup, so by the time one
//! of these exists they are known to run.
//!
//! The panel is a `VStack` of two: the line being typed, and what it matched.
//! The query says how tall it is -- one line, a rule, and the air around it --
//! and the list takes the rest, so neither has to be told where the other ends.
//!
//! Nothing is offered until something is typed. A list of every file in the
//! repository is not an answer to a question nobody has asked yet, and drawing
//! one would be a screenful of shaping done on the way to being replaced.

const std = @import("std");

const config = @import("../config.zig");
const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const Intent = event_mod.Intent;

const glyph_atlas = @import("../glyph_atlas.zig");
const GlyphAtlas = glyph_atlas.GlyphAtlas;
const LineLayout = glyph_atlas.LineLayout;

const painter_mod = @import("../painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const drawLine = @import("../text.zig").draw;
const advance = @import("../text.zig").advance;

const VStack = @import("./vstack.zig").VStack;

const tools = @import("../tools.zig");

/// Above a view's 0, 1 and 2, so the overlay covers the text rather than
/// interleaving with it.
const scrim_key: Key = .{ .layer = 3, .pipeline = .solid, .colour = config.scrim_colour };
const rule_key: Key = .{ .layer = 4, .pipeline = .solid, .colour = config.rule_colour };
const accent_key: Key = .{ .layer = 4, .pipeline = .solid, .colour = config.bad_colour };
const caret_key: Key = .{ .layer = 4, .pipeline = .solid, .colour = config.caret_colour };

/// Words, above both. Which of the three a row is set in is what says whether it
/// is the chosen one, so the colours are keys rather than an argument.
const text_key: Key = .{ .layer = 5, .pipeline = .glyphs, .colour = config.text_colour };
const muted_key: Key = .{ .layer = 5, .pipeline = .glyphs, .colour = config.muted_colour };
const faint_key: Key = .{ .layer = 5, .pipeline = .glyphs, .colour = config.faint_colour };

/// The column the whole thing is set in, as a share of the window, and where it
/// starts down it. Nothing is boxed: the scrim is the ground, and these two
/// numbers are the whole layout.
const column_share = 0.38;
const top_share = 0.20;

/// In points, scaled like the font.
const accent = 3;
const gap = 12;

/// Rows are set looser than body text. Air is most of what makes a list read as
/// set rather than dumped.
const leading = 1.45;

/// The most results on screen at once.
const visible_rows = 12;

/// A hairline, whatever the display scale.
fn hairline(atlas: *const GlyphAtlas) f32 {
    return @max(1, @round(atlas.scale));
}

/// The line being typed, with what it matched said quietly at the far end of the
/// same measure, and a rule under both.
const Query = struct {
    gpa: std.mem.Allocator,

    typed: std.ArrayList(u8) = .empty,
    layout: LineLayout = .{},

    /// How many of how many, drawn flush right. Set by the finder after it
    /// ranks, because only it knows the numbers.
    shown: usize = 0,
    total: usize = 0,
    count: LineLayout = .{},

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    dirty: bool = false,

    pub fn deinit(self: *Query) void {
        self.typed.deinit(self.gpa);
        self.layout.deinit(self.gpa);
        self.count.deinit(self.gpa);
    }

    /// One line, the rule under it, and the air either side of the rule. Stated
    /// here rather than by the panel because the panel cannot know that this is
    /// a line of text.
    pub fn height(self: *const Query, atlas: *const GlyphAtlas) ?f32 {
        _ = self;
        return atlas.line_height + 3 * @round(gap * atlas.scale);
    }

    pub fn place(self: *Query, rect: Rect, atlas: *const GlyphAtlas) void {
        _ = atlas;
        self.rect = rect;
    }

    pub fn isDirty(self: *const Query) bool {
        return self.dirty;
    }

    pub fn setDirty(self: *Query, value: bool) void {
        self.dirty = value;
    }

    pub fn invalidate(self: *Query) void {
        self.layout.shaped = false;
        self.count.shaped = false;
        self.dirty = true;
    }

    pub fn clear(self: *Query) void {
        self.typed.clearRetainingCapacity();
        self.shown = 0;
        self.total = 0;
        self.invalidate();
    }

    /// What the finder found, for the far end of the line.
    pub fn counted(self: *Query, shown: usize, total: usize) void {
        self.shown = shown;
        self.total = total;
        self.count.shaped = false;
        self.dirty = true;
    }

    pub fn update(self: *Query, event: Event, atlas: *GlyphAtlas) !Intent {
        _ = atlas;
        switch (event) {
            .text => |what| try self.typed.appendSlice(self.gpa, what),
            .backspace => {
                if (self.typed.items.len == 0) return .nothing;
                // One byte at a time is wrong the moment the query is not
                // ASCII, and `Buffer.stepBack` is where that is already solved;
                // this is a query, not a document, and cannot reach it.
                self.typed.items.len -= 1;
            },
            else => return .nothing,
        }

        // `shapeLine` marks what it shaped as done and nothing else clears it,
        // so without this the query is drawn once -- empty, on the frame it
        // opened -- and every character typed after goes on the panel without
        // appearing on it.
        self.layout.shaped = false;
        self.dirty = true;
        return .nothing;
    }

    pub fn draw(self: *Query, atlas: *GlyphAtlas, painter: *Painter) !void {
        const scale = atlas.scale;
        const spacing = @round(gap * scale);
        const right = self.rect.x + self.rect.width;
        const baseline = @round(self.rect.y + atlas.ascent);

        if (!self.layout.shaped) try atlas.shapeLine(self.typed.items, &self.layout);
        try drawLine(painter, text_key, &self.layout, .{ self.rect.x, baseline });

        try painter.add(caret_key, .solid(
            .{ @round(self.rect.x + advance(&self.layout)), @round(baseline - atlas.ascent) },
            .{ hairline(atlas), atlas.line_height },
        ));

        if (!self.count.shaped) {
            var buffer: [32]u8 = undefined;
            // Nothing typed, or everything matched: the total on its own, which
            // is what there is to search rather than what was found.
            const label = if (self.typed.items.len == 0 or self.shown == self.total)
                try std.fmt.bufPrint(&buffer, "{d}", .{self.total})
            else
                try std.fmt.bufPrint(&buffer, "{d} of {d}", .{ self.shown, self.total });
            try atlas.shapeLine(label, &self.count);
        }
        try drawLine(painter, faint_key, &self.count, .{ @round(right - advance(&self.count)), baseline });

        // A hairline across the measure, which is what says the query above it
        // and the list below it are one thing.
        try painter.add(rule_key, .solid(
            .{ self.rect.x, @round(self.rect.y + atlas.line_height + spacing) },
            .{ self.rect.width, hairline(atlas) },
        ));
    }
};

/// A row is set on two axes: the filename flush left, the directory it is in
/// flush right. The name is what is being chosen, so it gets the strong edge and
/// the strong colour.
const Row = struct {
    name: LineLayout = .{},
    directory: LineLayout = .{},

    fn deinit(self: *Row, gpa: std.mem.Allocator) void {
        self.name.deinit(gpa);
        self.directory.deinit(gpa);
    }
};

/// What the query matched, in fzf's order.
const Results = struct {
    gpa: std.mem.Allocator,

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
    dirty: bool = false,

    pub fn deinit(self: *Results) void {
        for (&self.rows) |*row| row.deinit(self.gpa);
    }

    /// Whatever is left under the query: a list is what a window has spare room
    /// for, not something with a size of its own.
    pub fn height(self: *const Results, atlas: *const GlyphAtlas) ?f32 {
        _ = self;
        _ = atlas;
        return null;
    }

    pub fn place(self: *Results, rect: Rect, atlas: *const GlyphAtlas) void {
        _ = atlas;
        self.rect = rect;
    }

    pub fn isDirty(self: *const Results) bool {
        return self.dirty;
    }

    pub fn setDirty(self: *Results, value: bool) void {
        self.dirty = value;
    }

    pub fn invalidate(self: *Results) void {
        self.laid_out = false;
        self.dirty = true;
    }

    /// Points at a new set of matches and goes back to the top of it.
    pub fn show(self: *Results, matches: []const []const u8) void {
        self.matches = matches;
        self.selected = 0;
        self.top_row = 0;
        self.laid_out = false;
        self.dirty = true;
    }

    /// What return would open.
    pub fn chosen(self: *const Results) ?[]const u8 {
        if (self.selected >= self.matches.len) return null;
        return self.matches[self.selected];
    }

    pub fn update(self: *Results, event: Event, atlas: *GlyphAtlas) !Intent {
        _ = atlas;
        switch (event) {
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
        self.dirty = true;
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

    pub fn draw(self: *Results, atlas: *GlyphAtlas, painter: *Painter) !void {
        try self.layOut(atlas);

        const scale = atlas.scale;
        const step = @round(atlas.line_height * leading);
        const spacing = @round(gap * scale);
        const left = self.rect.x;
        const right = self.rect.x + self.rect.width;

        for (&self.rows, 0..) |*row, index| {
            const which = self.top_row + index;
            if (which >= self.matches.len) break;

            const is_chosen = which == self.selected;
            const baseline = @round(self.rect.y + @as(f32, @floatFromInt(index)) * step + atlas.ascent);

            // The selection is the filename going black while the rest stay
            // grey, and a mark hanging in the margin. No bar behind it: value
            // carries it, and a bar would be the only box on the screen.
            if (is_chosen) {
                const mark = @round(accent * scale);
                try painter.add(accent_key, .solid(
                    .{ left - spacing - mark, @round(baseline - atlas.ascent) },
                    .{ mark, atlas.line_height },
                ));
            }

            const directory_width = advance(&row.directory);

            // A leader across the gap, on the chosen row only. Two flush edges
            // with nothing between them read as two lists; this is what a
            // contents page does about that. On every row it would be a texture
            // rather than a connection, so it goes where the eye already is.
            if (is_chosen and directory_width > 0) {
                const from = @round(left + advance(&row.name) + spacing);
                const to = @round(right - directory_width - spacing);
                if (to > from) try painter.add(rule_key, .solid(
                    .{ from, @round(baseline - atlas.ascent * 0.32) },
                    .{ to - from, hairline(atlas) },
                ));
            }

            try drawLine(painter, if (is_chosen) text_key else muted_key, &row.name, .{ left, baseline });
            try drawLine(painter, faint_key, &row.directory, .{ @round(right - directory_width), baseline });
        }
    }
};

/// The panel: what is being typed, and what it matched.
const Panel = VStack(&.{ Query, Results });

pub const Finder = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

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
    dirty: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !Finder {
        const rg = try tools.path(gpa, environ, .rg);
        errdefer gpa.free(rg);
        const fzf = try tools.path(gpa, environ, .fzf);

        return .{
            .gpa = gpa,
            .io = io,
            .rg = rg,
            .fzf = fzf,
            .panel = .init(.{ .{ .gpa = gpa }, .{ .gpa = gpa } }),
        };
    }

    pub fn deinit(self: *Finder) void {
        self.close();
        self.all.deinit(self.gpa);
        self.matches.deinit(self.gpa);
        self.panel.deinit();

        self.gpa.free(self.rg);
        self.gpa.free(self.fzf);
    }

    /// Everything that only exists while it is open. The listing is the one
    /// thing here that grows with the repository, so it does not outlive a
    /// closed finder.
    fn close(self: *Finder) void {
        self.showing = false;

        // Before the bytes go, since the rows point into them.
        self.panel.get(Results).show(&.{});
        self.panel.get(Query).clear();

        self.all.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();

        self.gpa.free(self.listing);
        self.listing = &.{};
        self.gpa.free(self.ranked);
        self.ranked = &.{};
    }

    pub fn isDirty(self: *const Finder) bool {
        return self.dirty or self.panel.isDirty();
    }

    pub fn setDirty(self: *Finder, value: bool) void {
        self.dirty = value;
        self.panel.setDirty(value);
    }

    /// The panel is a measure down the middle: a share of the width, a fifth of
    /// the way down, and as far as the window goes.
    pub fn place(self: *Finder, rect: Rect, atlas: *const GlyphAtlas) void {
        self.rect = rect;

        const column = @round(rect.width * column_share);
        const top = @round(rect.y + rect.height * top_share);
        self.panel.place(.{
            .x = @round(rect.x + (rect.width - column) / 2),
            .y = top,
            .width = column,
            .height = rect.y + rect.height - top,
        }, atlas);
    }

    pub fn invalidate(self: *Finder) void {
        self.panel.invalidate();
        self.dirty = true;
    }

    /// Reads what there is to choose between and shows the panel.
    pub fn show(self: *Finder) !void {
        self.close();
        self.showing = true;
        self.dirty = true;

        const result = try std.process.run(self.gpa, self.io, .{
            .argv = &.{ self.rg, "--files" },
            .stdout_limit = .limited(16 << 20),
        });
        defer self.gpa.free(result.stderr);
        errdefer self.gpa.free(result.stdout);

        self.listing = result.stdout;
        var lines = std.mem.splitScalar(u8, self.listing, '\n');
        while (lines.next()) |line| {
            if (line.len != 0) try self.all.append(self.gpa, line);
        }

        try self.rank();
    }

    /// The path it answers with is copied out of the listing, which closing
    /// frees, so whoever takes it owns it.
    pub fn update(self: *Finder, event: Event, atlas: *GlyphAtlas) !Intent {
        switch (event) {
            .cancel, .find => {
                self.close();
                return .dismiss;
            },
            .newline => {
                const picked = self.panel.get(Results).chosen() orelse return .nothing;
                const path = try self.gpa.dupe(u8, picked);
                self.close();
                return .{ .open = path };
            },
            // The selection is the list's, and the characters are the query's.
            // Both are in the panel; only the arrows are not for the one with
            // the keyboard, so they are handed over by name.
            .up, .down => return self.panel.get(Results).update(event, atlas),
            .text, .backspace => {
                _ = try self.panel.update(event, atlas);
                try self.rank();
                return .nothing;
            },
            else => return .nothing,
        }
    }

    /// Re-ranks against the query. Nothing typed is nothing offered: the whole
    /// repository is not an answer, and shaping a screenful of it would be work
    /// done on the way to being thrown away.
    fn rank(self: *Finder) !void {
        self.matches.clearRetainingCapacity();
        self.panel.get(Results).show(&.{});

        self.gpa.free(self.ranked);
        self.ranked = &.{};

        const query = self.panel.get(Query).typed.items;
        if (query.len != 0) {
            const filter = try std.fmt.allocPrint(self.gpa, "--filter={s}", .{query});
            defer self.gpa.free(filter);

            var child = try std.process.spawn(self.io, .{
                .argv = &.{ self.fzf, filter },
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .ignore,
            });
            errdefer child.kill(self.io);

            // Everything in, then the pipe closed, then everything out. Safe in
            // that order because `--filter` has to score every candidate before
            // it can sort them, so it writes nothing until stdin ends --
            // measured at 8.6MB each way without wedging.
            {
                var buffer: [64 * 1024]u8 = undefined;
                var writer = child.stdin.?.writer(self.io, &buffer);
                try writer.interface.writeAll(self.listing);
                try writer.interface.flush();
            }
            child.stdin.?.close(self.io);
            child.stdin = null;

            var buffer: [64 * 1024]u8 = undefined;
            var reader = child.stdout.?.reader(self.io, &buffer);
            self.ranked = try reader.interface.allocRemaining(self.gpa, .limited(16 << 20));

            _ = try child.wait(self.io);

            var lines = std.mem.splitScalar(u8, self.ranked, '\n');
            while (lines.next()) |line| {
                if (line.len != 0) try self.matches.append(self.gpa, line);
            }
        }

        self.panel.get(Results).show(self.matches.items);
        self.panel.get(Query).counted(self.matches.items.len, self.all.items.len);
    }

    pub fn draw(self: *Finder, atlas: *GlyphAtlas, painter: *Painter) !void {
        if (!self.showing) return;

        painter.clipTo(self.rect);
        defer painter.clipTo(null);

        // The ground the whole thing is set on. Everything below stays legible
        // through it, which is what keeps this an overlay rather than a
        // different screen.
        try painter.add(scrim_key, .solid(
            .{ self.rect.x, self.rect.y },
            .{ self.rect.width, self.rect.height },
        ));

        try self.panel.draw(atlas, painter);
    }
};
