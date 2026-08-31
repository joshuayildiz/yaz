//! A tab per file open in this window, along the top.
//!
//! Each is as wide as the name in it, packed from the left, so the bar reads as
//! labels rather than as a grid. That is why this lays its own tabs out instead
//! of being an `HList`, which divides evenly: a row of equal shares is the wrong
//! shape for a row of words.
//!
//! It owns the names and nothing else. Which file is in front of the reader is
//! asked of the columns every frame rather than remembered here, so the bar
//! cannot disagree with what is on screen.
//!
//! A press answers `Intent.open`, exactly as the finder does, and the same code
//! above puts the file in the column that has the keyboard.

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

/// Below the finder's 3 and above, and never over a document: the bar has the
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
    allocator: std.mem.Allocator,

    /// Every file open in this window, in the order they were first opened.
    /// Owned, because the copy a view or a parked document holds is freed and
    /// replaced as files move between them.
    paths: std.ArrayList([]u8) = .empty,
    names: std.ArrayList(LineLayout) = .empty,

    /// Whether each file has been changed since it was read. Told to the bar
    /// rather than worked out here: which documents exist is not its business.
    unsaved: std.ArrayList(bool) = .empty,

    /// Whether each file is in a column. Several are once the window is split,
    /// so this is not the same question as which one has the keyboard -- a tab
    /// says both, with the ground it is on and the colour of its name.
    in_column: std.ArrayList(bool) = .empty,

    /// The mark itself, shaped once. Its width is reserved on every tab whether
    /// it is drawn or not, so a file does not shift the bar by being typed into,
    /// and again on the other side of the name, so the name sits in the middle
    /// of the tab rather than hard against its right edge.
    bullet: LineLayout = .{},

    /// Where each one ended up, worked out while drawing, which is the only
    /// time the labels can be measured. A press comes after a frame, so there
    /// is always something to hit.
    rects: std.ArrayList(Rect) = .empty,

    /// Which of them the column with the keyboard is showing.
    front: ?usize = null,

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator) Tabs {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tabs) void {
        for (self.paths.items) |path| self.allocator.free(path);
        self.paths.deinit(self.allocator);
        for (self.names.items) |*name| name.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.unsaved.deinit(self.allocator);
        self.in_column.deinit(self.allocator);
        self.rects.deinit(self.allocator);
        self.bullet.deinit(self.allocator);
    }

    /// Lists `path` if it is not listed already.
    pub fn opened(self: *Tabs, path: []const u8) !void {
        for (self.paths.items) |listed| {
            if (std.mem.eql(u8, listed, path)) return;
        }

        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);

        try self.paths.append(self.allocator, owned);
        errdefer _ = self.paths.pop();
        try self.names.append(self.allocator, .{});
        errdefer _ = self.names.pop();
        try self.unsaved.append(self.allocator, false);
        errdefer _ = self.unsaved.pop();
        try self.in_column.append(self.allocator, false);
        try self.rects.append(self.allocator, .{ .x = 0, .y = 0, .width = 0, .height = 0 });
        self.dirty = true;
    }

    /// Where `path` sits on the bar, or none when it is not on it.
    pub fn indexOf(self: *const Tabs, path: []const u8) ?usize {
        for (self.paths.items, 0..) |listed, which| {
            if (std.mem.eql(u8, listed, path)) return which;
        }
        return null;
    }

    /// The nth file listed, or none when the bar is shorter than that.
    pub fn nth(self: *const Tabs, which: usize) ?[]const u8 {
        if (which >= self.paths.items.len) return null;
        return self.paths.items[which];
    }

    /// Takes `path` off the bar. Whether the file is still open anywhere is not
    /// the bar's business: whoever calls this has decided it is not.
    pub fn close(self: *Tabs, path: []const u8) void {
        for (self.paths.items, 0..) |listed, which| {
            if (!std.mem.eql(u8, listed, path)) continue;

            self.allocator.free(listed);
            _ = self.paths.orderedRemove(which);
            var name = self.names.orderedRemove(which);
            name.deinit(self.allocator);
            _ = self.unsaved.orderedRemove(which);
            _ = self.in_column.orderedRemove(which);
            _ = self.rects.orderedRemove(which);

            self.dirty = true;
            return;
        }
    }

    /// Whether `path` has been changed since it was read. A file the bar has
    /// never heard of is not an error: it is one nobody has opened.
    pub fn mark(self: *Tabs, path: []const u8, unsaved: bool) void {
        for (self.paths.items, 0..) |listed, which| {
            if (!std.mem.eql(u8, listed, path)) continue;
            if (self.unsaved.items[which] != unsaved) {
                self.unsaved.items[which] = unsaved;
                self.dirty = true;
            }
            return;
        }
    }

    /// Forgets which files are in columns. Asked again every frame rather than
    /// kept in step, because a file leaves a column without the bar being told.
    pub fn forgetColumns(self: *Tabs) void {
        for (self.in_column.items) |*shown| shown.* = false;
    }

    /// Says a column is showing `path`. Several may be.
    pub fn columnShows(self: *Tabs, path: []const u8) void {
        const which = self.indexOf(path) orelse return;
        if (!self.in_column.items[which]) {
            self.in_column.items[which] = true;
            self.dirty = true;
        }
    }

    /// Which file the column with the keyboard is showing, or none for a
    /// document nobody named.
    pub fn showing(self: *Tabs, path: ?[]const u8) void {
        const found: ?usize = if (path) |named| found: {
            for (self.paths.items, 0..) |listed, which| {
                if (std.mem.eql(u8, listed, named)) break :found which;
            }
            break :found null;
        } else null;

        if (found != self.front) {
            self.front = found;
            self.dirty = true;
        }
    }

    /// Nothing at all when no file has been named: a strip with no tabs on it
    /// is a promise of something that is not there.
    pub fn height(self: *const Tabs, atlas: *const GlyphAtlas) ?f32 {
        if (self.paths.items.len == 0) return 0;
        return @round(atlas.line_height + 2 * @round(down * atlas.scale));
    }

    pub fn place(self: *Tabs, rect: Rect, atlas: *const GlyphAtlas) void {
        _ = atlas;
        self.rect = rect;
    }

    pub fn isDirty(self: *const Tabs) bool {
        return self.dirty;
    }

    pub fn setDirty(self: *Tabs, value: bool) void {
        self.dirty = value;
    }

    pub fn invalidate(self: *Tabs) void {
        for (self.names.items) |*name| name.shaped = false;
        self.bullet.shaped = false;
        self.dirty = true;
    }

    pub fn update(self: *Tabs, event: Event, atlas: *GlyphAtlas) !Intent {
        _ = atlas;
        const at = switch (event) {
            .press => |where| where,
            else => return .nothing,
        };

        for (self.rects.items, 0..) |rect, which| {
            if (!rect.contains(at)) continue;
            // Pressing a tab is choosing that file over the others, which is
            // what cmd+N means too. The finder answers `open` instead: picking
            // a file there is not a statement about the ones already on screen.
            return .{ .only = try self.allocator.dupe(u8, self.paths.items[which]) };
        }
        return .nothing;
    }

    pub fn draw(self: *Tabs, atlas: *GlyphAtlas, painter: *Painter) !void {
        if (self.paths.items.len == 0) return;

        const line = @max(1, @round(atlas.scale));
        const inset = @round(across * atlas.scale);
        const gap = @round(beside * atlas.scale);

        if (!self.bullet.shaped) try atlas.shapeLine(unsaved_mark, &self.bullet);

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
        for (self.paths.items, 0..) |path, which| {
            const name = &self.names.items[which];
            if (!name.shaped) try atlas.shapeLine(std.fs.path.basename(path), name);

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
            const on_screen = self.in_column.items[which];
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

            const key = if (which == self.front) name_key else other_key;
            const baseline = @round(self.rect.y + @round(down * atlas.scale) + atlas.ascent);

            // The mark's room is taken whether or not it is drawn, so a file
            // being typed into does not push the rest of the bar along; the
            // same room again on the right is what centres the name.
            if (self.unsaved.items[which]) {
                // Placed by its ink rather than by its pen, so what was
                // reserved is what appears there.
                try drawLine(painter, key, &self.bullet, .{ @round(left + inset - ink.from), baseline });
            }
            try drawLine(painter, key, name, .{ @round(left + inset + ink.wide + gap), baseline });

            left += width;
        }
    }
};
