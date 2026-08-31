//! The file finder: cmd+P, type, arrow keys, return.
//!
//! It does no listing and no matching of its own. `rg --files` says what there
//! is to choose between, honouring .gitignore, and `fzf --filter` ranks it
//! against what has been typed. Both are checked at startup, so by the time one
//! of these exists they are known to run.
//!
//! An overlay rather than a column: it covers whatever is behind it and gives
//! the room back untouched when it closes.

const std = @import("std");

const config = @import("../config.zig");
const Event = @import("../event.zig").Event;

const glyph_atlas = @import("../glyph_atlas.zig");
const GlyphAtlas = glyph_atlas.GlyphAtlas;
const LineLayout = glyph_atlas.LineLayout;

const painter_mod = @import("../painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const drawLine = @import("../text.zig").draw;
const advance = @import("../text.zig").advance;

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

const Row = struct {
    name: LineLayout = .{},
    directory: LineLayout = .{},
};

pub const Finder = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    /// Resolved once. Both are known to run: startup refused to get this far
    /// otherwise.
    rg: []u8,
    fzf: []u8,

    showing: bool = false,
    query: std.ArrayList(u8) = .empty,

    /// `rg --files` verbatim, with `all` pointing into it. One allocation for
    /// the whole listing rather than one per path.
    listing: []u8 = &.{},
    all: std.ArrayList([]const u8) = .empty,

    /// `fzf --filter` verbatim, with `matches` pointing into it. Empty when the
    /// query is, and then `matches` points into `listing` instead.
    ranked: []u8 = &.{},
    matches: std.ArrayList([]const u8) = .empty,

    selected: usize = 0,
    /// The first match on screen. Follows `selected` rather than leading it.
    top_row: usize = 0,

    query_layout: LineLayout = .{},
    count_layout: LineLayout = .{},

    /// A row is set on two axes: the filename flush left, the directory it is
    /// in flush right. The name is what is being chosen, so it gets the strong
    /// edge and the strong colour.
    rows: std.ArrayList(Row) = .empty,
    /// Whether `rows` describes the matches currently on screen.
    laid_out: bool = false,

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    dirty: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !Finder {
        const rg = try tools.path(gpa, environ, .rg);
        errdefer gpa.free(rg);
        const fzf = try tools.path(gpa, environ, .fzf);

        return .{ .gpa = gpa, .io = io, .rg = rg, .fzf = fzf };
    }

    pub fn deinit(self: *Finder) void {
        self.close();
        self.query.deinit(self.gpa);
        self.all.deinit(self.gpa);
        self.matches.deinit(self.gpa);

        self.query_layout.deinit(self.gpa);
        self.count_layout.deinit(self.gpa);
        for (self.rows.items) |*row| {
            row.name.deinit(self.gpa);
            row.directory.deinit(self.gpa);
        }
        self.rows.deinit(self.gpa);

        self.gpa.free(self.rg);
        self.gpa.free(self.fzf);
    }

    /// Everything that only exists while it is open. The listing is the one
    /// thing here that grows with the repository, so it does not outlive a
    /// closed finder.
    fn close(self: *Finder) void {
        self.showing = false;
        self.query.clearRetainingCapacity();
        self.all.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();

        self.gpa.free(self.listing);
        self.listing = &.{};
        self.gpa.free(self.ranked);
        self.ranked = &.{};

        self.selected = 0;
        self.top_row = 0;
        self.laid_out = false;
    }

    pub fn isOpen(self: *const Finder) bool {
        return self.showing;
    }

    pub fn isDirty(self: *const Finder) bool {
        return self.dirty;
    }

    pub fn setDirty(self: *Finder, value: bool) void {
        self.dirty = value;
    }

    pub fn place(self: *Finder, rect: Rect) void {
        self.rect = rect;
    }

    pub fn invalidate(self: *Finder) void {
        self.query_layout.shaped = false;
        self.count_layout.shaped = false;
        self.laid_out = false;
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

    /// What the panel is showing, and what return would open.
    ///
    /// Answers with a path when one was chosen, which the caller owns nothing
    /// of -- it points into the listing, and is gone when the finder closes.
    pub fn update(self: *Finder, event: Event) !?[]const u8 {
        self.dirty = true;

        switch (event) {
            .cancel, .find => {
                self.close();
                return null;
            },
            .newline => {
                const picked = self.chosen() orelse return null;

                // Copied before closing, because closing frees what it points
                // into.
                const path = try self.gpa.dupe(u8, picked);
                self.close();
                return path;
            },
            .up => {
                if (self.selected > 0) self.selected -= 1;
                self.follow();
            },
            .down => {
                if (self.selected + 1 < self.matches.items.len) self.selected += 1;
                self.follow();
            },
            .text => |typed| {
                try self.query.appendSlice(self.gpa, typed);
                try self.rank();
            },
            .backspace => {
                if (self.query.items.len == 0) return null;
                // One byte at a time is wrong the moment the query is not
                // ASCII, and `Buffer.stepBack` is where that is already solved;
                // this is a query, not a document, and cannot reach it.
                self.query.items.len -= 1;
                try self.rank();
            },
            // The pointer is not wired up yet, and the window's own events were
            // dealt with above this.
            else => self.dirty = false,
        }
        return null;
    }

    fn chosen(self: *const Finder) ?[]const u8 {
        if (self.selected >= self.matches.items.len) return null;
        return self.matches.items[self.selected];
    }

    /// Keeps the selection on screen, without moving further than it has to.
    fn follow(self: *Finder) void {
        if (self.selected < self.top_row) self.top_row = self.selected;
        if (self.selected >= self.top_row + visible_rows) {
            self.top_row = self.selected + 1 - visible_rows;
        }
        self.laid_out = false;
    }

    /// Re-ranks against the query. An empty one is every candidate in the order
    /// ripgrep gave them; anything else is fzf's order.
    fn rank(self: *Finder) !void {
        // The query is shaped like any other line, and `shapeLine` marks what
        // it shaped as done. Nothing else clears that, so without this the
        // query is drawn once -- empty, on the frame it opened -- and every
        // character typed after goes on the panel without appearing on it.
        self.query_layout.shaped = false;
        self.count_layout.shaped = false;

        self.matches.clearRetainingCapacity();
        self.selected = 0;
        self.top_row = 0;
        self.laid_out = false;

        self.gpa.free(self.ranked);
        self.ranked = &.{};

        if (self.query.items.len == 0) {
            try self.matches.appendSlice(self.gpa, self.all.items);
            return;
        }

        const filter = try std.fmt.allocPrint(self.gpa, "--filter={s}", .{self.query.items});
        defer self.gpa.free(filter);

        var child = try std.process.spawn(self.io, .{
            .argv = &.{ self.fzf, filter },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(self.io);

        // Everything in, then the pipe closed, then everything out. Safe in
        // that order because `--filter` has to score every candidate before it
        // can sort them, so it writes nothing until stdin ends -- measured at
        // 8.6MB each way without wedging.
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

        const scale = atlas.scale;
        const step = @round(atlas.line_height * leading);
        const spacing = @round(gap * scale);

        const column = @round(self.rect.width * column_share);
        const left = @round(self.rect.x + (self.rect.width - column) / 2);
        const right = left + column;
        const top = @round(self.rect.y + self.rect.height * top_share);

        // The query, on its own line, with what it matched said quietly at the
        // far end of the same measure.
        const query_baseline = @round(top + atlas.ascent);
        if (!self.query_layout.shaped) try atlas.shapeLine(self.query.items, &self.query_layout);
        try drawLine(painter, text_key, &self.query_layout, .{ left, query_baseline });

        const caret_x = @round(left + advance(&self.query_layout));
        try painter.add(caret_key, .solid(
            .{ caret_x, @round(query_baseline - atlas.ascent) },
            .{ @max(1, @round(scale)), atlas.line_height },
        ));

        try self.shapeCount(atlas);
        try drawLine(
            painter,
            faint_key,
            &self.count_layout,
            .{ @round(right - advance(&self.count_layout)), query_baseline },
        );

        // A hairline across the measure, which is what says the query above it
        // and the list below it are one thing.
        const rule_y = @round(top + atlas.line_height + spacing);
        try painter.add(rule_key, .solid(.{ left, rule_y }, .{ column, @max(1, @round(scale)) }));

        try self.layOut(atlas);

        const first_top = @round(rule_y + spacing * 2);
        for (self.rows.items, 0..) |*row, index| {
            const which = self.top_row + index;
            if (which >= self.matches.items.len) break;

            const chosen_row = which == self.selected;
            const baseline = @round(first_top + @as(f32, @floatFromInt(index)) * step + atlas.ascent);

            // The selection is the filename going black while the rest stay
            // grey, and a mark hanging in the margin. No bar behind it: value
            // carries it, and a bar would be the only box on the screen.
            if (chosen_row) {
                const mark = @round(accent * scale);
                try painter.add(accent_key, .solid(
                    .{ left - spacing - mark, @round(baseline - atlas.ascent) },
                    .{ mark, atlas.line_height },
                ));
            }

            const name_width = advance(&row.name);
            const directory_width = advance(&row.directory);

            // A leader across the gap, on the chosen row only. Two flush edges
            // with nothing between them read as two lists; this is what a
            // contents page does about that. On every row it would be a texture
            // rather than a connection, so it goes where the eye already is.
            if (chosen_row and directory_width > 0) {
                const from = @round(left + name_width + spacing);
                const to = @round(right - directory_width - spacing);
                if (to > from) try painter.add(rule_key, .solid(
                    .{ from, @round(baseline - atlas.ascent * 0.32) },
                    .{ to - from, @max(1, @round(scale)) },
                ));
            }

            try drawLine(
                painter,
                if (chosen_row) text_key else muted_key,
                &row.name,
                .{ left, baseline },
            );
            try drawLine(painter, faint_key, &row.directory, .{ @round(right - directory_width), baseline });
        }
    }

    fn shapeCount(self: *Finder, atlas: *GlyphAtlas) !void {
        if (self.count_layout.shaped) return;

        var buffer: [32]u8 = undefined;
        const text = if (self.matches.items.len == self.all.items.len)
            try std.fmt.bufPrint(&buffer, "{d}", .{self.all.items.len})
        else
            try std.fmt.bufPrint(&buffer, "{d} of {d}", .{ self.matches.items.len, self.all.items.len });

        try atlas.shapeLine(text, &self.count_layout);
    }

    /// Shapes the rows on screen, and only those: the match set is the whole
    /// repository until something is typed, and shaping it would be shaping
    /// thousands of lines nobody is looking at.
    fn layOut(self: *Finder, atlas: *GlyphAtlas) !void {
        if (self.laid_out) return;

        try self.rows.ensureTotalCapacity(self.gpa, visible_rows);
        while (self.rows.items.len < visible_rows) self.rows.appendAssumeCapacity(.{});

        for (self.rows.items, 0..) |*row, index| {
            const which = self.top_row + index;
            if (which >= self.matches.items.len) {
                row.name.sprites.clearRetainingCapacity();
                row.directory.sprites.clearRetainingCapacity();
                continue;
            }

            const path = self.matches.items[which];
            try atlas.shapeLine(std.fs.path.basename(path), &row.name);

            // Everything up to the last separator, kept: two files of the same
            // name are told apart by what is in front of them, and that is the
            // whole reason the directory is on the row at all.
            const directory = std.fs.path.dirname(path) orelse "";
            try atlas.shapeLine(directory, &row.directory);
        }
        self.laid_out = true;
    }
};
