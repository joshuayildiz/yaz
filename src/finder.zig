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

const config = @import("./config.zig");
const Event = @import("./event.zig").Event;

const glyph_atlas = @import("./glyph_atlas.zig");
const GlyphAtlas = glyph_atlas.GlyphAtlas;
const LineLayout = glyph_atlas.LineLayout;

const painter_mod = @import("./painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const tools = @import("./tools.zig");

/// Above a view's 0, 1 and 2, so the overlay covers the text rather than
/// interleaving with it.
const panel_key: Key = .{ .layer = 3, .pipeline = .solid, .colour = config.panel_colour };
const selection_key: Key = .{ .layer = 4, .pipeline = .solid, .colour = config.chip_colour };
const caret_key: Key = .{ .layer = 5, .pipeline = .solid, .colour = config.caret_colour };
const text_layer = 5;

/// In points, scaled like the font.
const pad = 14;
const margin_top = 90;
const width_share = 0.62;

/// The most results on screen at once. Fewer matches make a shorter panel
/// rather than a panel with empty rows in it.
const visible_rows = 12;

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
    rows: std.ArrayList(LineLayout) = .empty,
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

        self.query_layout.sprites.deinit(self.gpa);
        self.query_layout.carets.deinit(self.gpa);
        for (self.rows.items) |*row| {
            row.sprites.deinit(self.gpa);
            row.carets.deinit(self.gpa);
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

        const scale = atlas.scale;
        const step = atlas.line_height;
        const padding = @round(pad * scale);

        const width = @round(self.rect.width * width_share);
        const left = @round(self.rect.x + (self.rect.width - width) / 2);
        const top = @round(self.rect.y + margin_top * scale);

        // A row for the query, a gap, then as many results as there are, up to
        // what fits.
        const shown = @min(self.matches.items.len, visible_rows);
        const rows_shown: f32 = @floatFromInt(shown);
        const height = @round(2 * padding + step * (rows_shown + 2));

        const panel: Rect = .{ .x = left, .y = top, .width = width, .height = height };
        painter.clipTo(panel);
        defer painter.clipTo(null);

        try painter.add(panel_key, .solid(.{ left, top }, .{ width, height }));

        const text_left = left + padding;
        const query_baseline = @round(top + padding + atlas.ascent);

        if (!self.query_layout.shaped) try atlas.shapeLine(self.query.items, &self.query_layout);
        try put(painter, &self.query_layout, .{ text_left, query_baseline }, config.text_colour);

        // Where the next character would land, which is the end of the query:
        // there is no cursor movement in here to put it anywhere else.
        const carets = self.query_layout.carets.items;
        const caret_x = @round(text_left + if (carets.len == 0) 0 else carets[carets.len - 1].x);
        try painter.add(caret_key, .solid(
            .{ caret_x, @round(query_baseline - atlas.ascent) },
            .{ @max(1, @round(scale)), step },
        ));

        try self.layOut(atlas);

        const first_row_top = @round(top + padding + 2 * step);
        for (self.rows.items, 0..) |*row, index| {
            const which = self.top_row + index;
            if (which >= self.matches.items.len) break;

            const row_top = first_row_top + @as(f32, @floatFromInt(index)) * step;
            if (which == self.selected) {
                try painter.add(selection_key, .solid(
                    .{ left, row_top },
                    .{ width, step },
                ));
            }

            try put(
                painter,
                row,
                .{ text_left, @round(row_top + atlas.ascent) },
                if (which == self.selected) config.text_colour else config.muted_colour,
            );
        }
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
                row.sprites.clearRetainingCapacity();
                row.carets.clearRetainingCapacity();
                continue;
            }
            try atlas.shapeLine(self.matches.items[which], row);
        }
        self.laid_out = true;
    }

    fn put(painter: *Painter, layout: *const LineLayout, at: [2]f32, colour: [4]f32) !void {
        const key: Key = .{ .layer = text_layer, .pipeline = .glyphs, .colour = colour };
        try painter.reserve(layout.sprites.items.len);
        for (layout.sprites.items) |sprite| {
            try painter.add(key, .{
                .dest = .{ sprite.dest[0] + at[0], sprite.dest[1] + at[1] },
                .source = sprite.source,
                .size = sprite.size,
            });
        }
    }
};
