//! A view of a document: the text, where the caret sits in it, and the shaped
//! layout of every line.
//!
//! The layout cache lives here rather than with the atlas because it belongs to
//! a view rather than to a font. One atlas serves every document; each view of
//! one caches its own lines. Holding the document beside the cache is also what
//! makes them impossible to get out of step -- an edit and the splice that
//! answers it are one call, not two that a caller has to remember to pair.

const std = @import("std");

const config = @import("./config.zig");
const Event = @import("./event.zig").Event;
const painter_mod = @import("./painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
pub const Rect = painter_mod.Rect;

const Buffer = @import("./document.zig").Buffer;
const Edit = @import("./document.zig").Edit;

const glyph_atlas = @import("./glyph_atlas.zig");
const Caret = glyph_atlas.Caret;
const GlyphAtlas = glyph_atlas.GlyphAtlas;
const LineLayout = glyph_atlas.LineLayout;
const Sprite = glyph_atlas.Sprite;

/// At a display scale of one, and scaled with the text: a hairline is the first
/// thing to disappear on a dense display, and the caret is the one mark that has
/// to be found without looking for it.
const caret_width = 2;

/// How wide the scrollbar is and how far it sits from the left edge, at a
/// display scale of one.
const bar_width = 8;
const bar_inset = 3;

/// The room the scrollbar takes down the left, which the text starts after.
const bar_gutter = bar_inset + bar_width;

/// The shortest the thumb is allowed to get. A long document would otherwise
/// scale it down to something there is no catching with a pointer.
const bar_minimum = 24;

/// Where the first line's top-left corner sits inside the rect, at a display
/// scale of one. Measured from the scrollbar rather than from the edge, since
/// the bar is down the left and the text starts after it.
const text_margin: [2]f32 = .{ 5, 5 };

/// What this view draws with. Glyphs sample the atlas; the caret and the
/// scrollbar do not, and each sits a layer above what it has to cover.
const glyph_key: Key = .{ .layer = 0, .pipeline = .glyphs, .colour = config.text_colour };
const caret_key: Key = .{ .layer = 1, .pipeline = .solid, .colour = config.caret_colour };
const bar_key: Key = .{ .layer = 2, .pipeline = .solid, .colour = config.scrollbar_colour };

pub const TextView = struct {
    gpa: std.mem.Allocator,
    document: Buffer,

    /// One entry per line of the document, in the document's order. Shaping is
    /// the expensive half of laying a line out and depends only on the line's
    /// bytes, so it is done once and kept.
    lines: std.ArrayList(LineLayout) = .empty,

    /// Where the next character lands, as a byte offset into the document, and
    /// where the caret is drawn. One number rather than a line and a column:
    /// every edit already speaks in offsets, and a pair would be a second thing
    /// to keep in step for no gain.
    cursor: usize,

    /// How far down the document the window sits, in whole pixels. A fraction
    /// would re-round every baseline independently and the text would shimmer
    /// as it moved.
    scroll: f32 = 0,

    /// What is left of a gesture too small to have moved a whole pixel yet. A
    /// trackpad reports fractions, and without this a slow drag would round
    /// away to nothing every event.
    pending: f32 = 0,

    /// Set by an edit, acted on by `scrollToCaret`. Typing that has gone off
    /// screen brings the view back; clicking reads the view where it is.
    follow_caret: bool = false,

    /// The room this view has been given. Everything it draws and everything it
    /// is asked about a point on screen is measured from here.
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    /// Where on the thumb the pointer took hold, while it is holding it. Null
    /// the rest of the time, which is also the answer to whether a drag is on.
    drag: ?f32 = null,

    /// Something changed that has not been drawn yet. Read through `isDirty`
    /// and cleared through `setDirty`, so that a view holding views of its own
    /// can answer for all of them.
    dirty: bool = false,

    /// The caret starts at the top: nothing scrolls yet, so a caret at the end
    /// of a long file is one nobody can see.
    pub fn init(gpa: std.mem.Allocator, text: []const u8) !TextView {
        return .{
            .gpa = gpa,
            .document = try Buffer.init(gpa, text),
            .cursor = 0,
        };
    }

    pub fn deinit(self: *TextView) void {
        for (self.lines.items) |*entry| {
            entry.sprites.deinit(self.gpa);
            entry.carets.deinit(self.gpa);
        }
        self.lines.deinit(self.gpa);
        self.document.deinit();
    }

    pub fn insert(self: *TextView, text: []const u8) !void {
        const edit = try self.document.insert(self.cursor, text);
        try self.splice(edit);
        self.cursor += text.len;
        self.follow_caret = true;
    }

    /// Deletes the character before the caret, answering whether there was one.
    pub fn backspace(self: *TextView) !bool {
        const from = self.document.stepBack(self.cursor);
        if (from == self.cursor) return false;

        const edit = self.document.delete(from, self.cursor - from);
        try self.splice(edit);
        self.cursor = from;
        self.follow_caret = true;
        return true;
    }

    /// Whether anything here has changed since it was last drawn.
    pub fn isDirty(self: *const TextView) bool {
        return self.dirty;
    }

    pub fn setDirty(self: *TextView, value: bool) void {
        self.dirty = value;
    }

    /// Hands the view the room it has. Called before anything is drawn or asked
    /// about, so nothing else has to be told the window's size.
    pub fn place(self: *TextView, rect: Rect) void {
        self.rect = rect;
    }

    /// Everything that happens inside the view. What belongs to the window has
    /// been dealt with before this is called.
    pub fn update(self: *TextView, event: Event, atlas: *GlyphAtlas) !void {
        switch (event) {
            .quit, .resized => {},
            .text => |typed| {
                try self.insert(typed);
                self.dirty = true;
            },
            .newline => {
                try self.insert("\n");
                self.dirty = true;
            },
            .backspace => self.dirty = try self.backspace() or self.dirty,
            .wheel => |wheel| {
                self.scrollBy(wheel.delta, atlas);
                self.dirty = true;
            },
            .press => |at| {
                // The scrollbar is asked first, so a press on it moves the view
                // rather than the caret.
                if (self.thumbGrab(atlas, at)) |grab| {
                    self.drag = grab;
                    self.dragTo(atlas, at[1], grab);
                    self.dirty = true;
                    return;
                }
                try self.moveCaretTo(atlas, at);
                self.dirty = true;
            },
            .move => |at| {
                // The only reason motion is looked at at all: OPTIMIZATIONS.md 2
                // has the loop ignoring it, and a redraw per motion event is what
                // that buys.
                const grab = self.drag orelse return;
                self.dragTo(atlas, at[1], grab);
                self.dirty = true;
            },
            .release => self.drag = null,
        }
    }

    /// Where the first line's top-left corner sits. Whole pixels, which the
    /// layout cache depends on: a fractional origin would change which subpixel
    /// variant every cached glyph points at.
    fn origin(self: *const TextView, atlas: *const GlyphAtlas) [2]f32 {
        return .{
            @round(self.rect.x + (bar_gutter + text_margin[0]) * atlas.scale),
            @round(self.rect.y + text_margin[1] * atlas.scale),
        };
    }

    /// Moves the view by `pixels`, keeping the offset a whole number of them.
    /// What is left over waits for the next event rather than rounding away.
    pub fn scrollBy(self: *TextView, pixels: f32, atlas: *const GlyphAtlas) void {
        self.pending += pixels;
        const whole = @trunc(self.pending);
        self.pending -= whole;
        self.scrollTo(self.scroll + whole, atlas);
    }

    /// Where the scrollbar's thumb sits in a window `height` tall.
    fn scrollbar(self: *const TextView, atlas: *const GlyphAtlas) Thumb {
        const count: f32 = @floatFromInt(self.document.lineCount());
        const content = self.origin(atlas)[1] - self.rect.y + count * atlas.line_height;
        return thumb(self.scroll, content, self.rect.height, @round(bar_minimum * atlas.scale));
    }

    /// Where on the thumb a press at `point` takes hold, or null when the press
    /// was not on the scrollbar at all.
    ///
    /// The whole gutter answers, not just the thumb's own width: a bar eight
    /// points wide is a small thing to ask anyone to hit. A press on the track
    /// rather than the thumb takes hold of its middle, so the thumb jumps to the
    /// pointer and carries on from there.
    pub fn thumbGrab(self: *const TextView, atlas: *const GlyphAtlas, point: [2]f32) ?f32 {
        const from_left = point[0] - self.rect.x;
        if (from_left < 0 or from_left >= @round(bar_gutter * atlas.scale)) return null;

        const t = self.scrollbar(atlas);
        const offset = point[1] - self.rect.y - t.y;
        if (offset < 0 or offset >= t.height) return t.height / 2;
        return offset;
    }

    /// Drags the thumb so that the point `grab` down it sits at `y`.
    pub fn dragTo(self: *TextView, atlas: *const GlyphAtlas, y: f32, grab: f32) void {
        if (self.rect.height <= 0) return;
        const count: f32 = @floatFromInt(self.document.lineCount());
        // The inverse of the thumb, whose top is `scroll * height / content`.
        const content = self.origin(atlas)[1] - self.rect.y + count * atlas.line_height;
        self.pending = 0;
        self.scrollTo(@round((y - self.rect.y - grab) * content / self.rect.height), atlas);
    }

    /// Brings the caret's line into view, and clears the flag that asked for it.
    pub fn scrollToCaret(self: *TextView, atlas: *const GlyphAtlas) void {
        self.follow_caret = false;
        const index = self.document.lineAt(self.cursor);
        // A jump is not a gesture, so anything a gesture had part-way through
        // it goes rather than being applied on top of the answer.
        self.pending = 0;
        const top = self.origin(atlas)[1] - self.rect.y;
        self.scrollTo(scrollToCentre(self.scroll, index, top, self.rect.height, atlas.line_height), atlas);
    }

    fn scrollTo(self: *TextView, to: f32, atlas: *const GlyphAtlas) void {
        self.scroll = @min(self.furthest(atlas), @max(0, to));
    }

    /// The far end of the scroll: where the last line reaches the top of the
    /// window rather than the bottom, so the end of a file stops being somewhere
    /// the view cannot follow you to. A document shorter than the window scrolls
    /// by the same rule.
    fn furthest(self: *const TextView, atlas: *const GlyphAtlas) f32 {
        const last = self.document.lineCount() -| 1;
        const top = self.origin(atlas)[1] - self.rect.y;
        return @max(0, @ceil(top + @as(f32, @floatFromInt(last)) * atlas.line_height));
    }

    /// Places every line's glyphs on screen, shaping the ones whose text has
    /// changed since they were last seen. `top` is the top of the first line,
    /// not its baseline.
    ///
    /// A redraw that changed nothing shapes nothing and does not so much as
    /// read the document; a keystroke shapes the one line it landed in. What
    /// remains per frame is placing the cached glyphs, which has to happen
    /// anyway to fill the buffer the GPU reads.
    pub fn draw(self: *TextView, atlas: *GlyphAtlas, painter: *Painter) !void {
        // Nothing this view draws may reach outside the room it was given: a
        // long line runs past the right edge, and a line at the bottom is only
        // partly on screen.
        painter.clipTo(self.rect);
        defer painter.clipTo(null);

        const at = self.origin(atlas);
        const x = at[0];
        const top = at[1] - self.rect.y;
        const height = self.rect.height;
        std.debug.assert(self.scroll == @round(self.scroll));

        const count = self.document.lineCount();
        if (self.lines.items.len == 0) try self.lines.appendNTimes(self.gpa, .{}, count);
        // Anything else means an edit did not reach the cache and the entries
        // no longer line up with the lines they describe.
        std.debug.assert(self.lines.items.len == count);

        const caret_line = self.document.lineAt(self.cursor);
        // Filled in as that line comes round, so the caret is placed from the
        // same shaped layout as the glyphs it sits between.
        var caret: ?Sprite = null;

        const range = visibleLines(top, self.scroll, height, atlas.line_height, count);
        for (self.lines.items[range.first..range.last], range.first..) |*entry, index| {
            if (!entry.shaped) try atlas.shapeLine(try self.document.lineSlice(index), entry);
            std.debug.assert(entry.bytes == self.document.lineLength(index));

            const baseline = @round(self.rect.y + lineTop(index, top, self.scroll, atlas.line_height) + atlas.ascent);
            try painter.reserve(entry.sprites.items.len);
            for (entry.sprites.items) |sprite| {
                try painter.add(glyph_key, .{
                    .dest = .{ sprite.dest[0] + x, sprite.dest[1] + baseline },
                    .source = sprite.source,
                    .size = sprite.size,
                });
            }

            if (index == caret_line) caret = self.caretOn(atlas, entry, index, x, baseline);
        }

        // The caret can be outside the range drawn, above it or below it. Its
        // quad is added anyway, out where the GPU discards it, so that where it
        // is never has to be a special case. Nothing partly on screen reaches
        // here, so where exactly it lands does not matter.
        if (caret == null) {
            const entry = &self.lines.items[caret_line];
            if (!entry.shaped) try atlas.shapeLine(try self.document.lineSlice(caret_line), entry);
            std.debug.assert(entry.bytes == self.document.lineLength(caret_line));

            const off = self.rect.y + lineTop(caret_line, top, self.scroll, atlas.line_height) + atlas.ascent;
            caret = self.caretOn(atlas, entry, caret_line, x, @round(off));
        }
        try painter.add(caret_key, caret.?);

        const t = self.scrollbar(atlas);
        try painter.add(bar_key, .solid(
            .{ @round(self.rect.x + bar_inset * atlas.scale), self.rect.y + t.y },
            .{ @round(bar_width * atlas.scale), t.height },
        ));
    }

    /// The caret's quad on `index`, whose layout must already be shaped.
    fn caretOn(
        self: *const TextView,
        atlas: *const GlyphAtlas,
        entry: *const LineLayout,
        index: usize,
        x: f32,
        baseline: f32,
    ) Sprite {
        const offset = self.cursor - self.document.lineStart(index);
        return .solid(.{
            x + @round(caretX(entry.carets.items, offset)),
            baseline - @round(atlas.ascent),
        }, .{ @round(caret_width * atlas.scale), @round(atlas.line_height) });
    }

    /// `x` and `top` are the origin the layout was placed at, and `point` is in
    /// the same coordinates.
    ///
    /// A click below the last line or right of a line's end lands on the nearest
    /// place the caret can go, which is what makes dragging past the end behave.
    pub fn moveCaretTo(self: *TextView, atlas: *GlyphAtlas, point: [2]f32) !void {
        // Nothing has been laid out, so there is nothing on screen to click.
        if (self.lines.items.len == 0) return;

        const at = self.origin(atlas);
        const row = (point[1] - at[1] + self.scroll) / atlas.line_height;
        const index = if (row < 0)
            0
        else
            @min(self.document.lineCount() - 1, @as(usize, @intFromFloat(row)));

        // A click lands on a line that was drawn, but the row arithmetic
        // clamps, and what it clamps to need not have been.
        const entry = &self.lines.items[index];
        if (!entry.shaped) try atlas.shapeLine(try self.document.lineSlice(index), entry);

        self.cursor = self.document.lineStart(index) + caretOffset(entry.carets.items, point[0] - at[0]);
    }

    /// Drops every shaped line, for after the atlas is rebuilt at a different
    /// scale. Nothing cached survives that: the positions are in pixels of the
    /// old size, and scaling them is not the same answer, because hinting and
    /// rounding do not distribute over a scale.
    ///
    /// The entries stay, so the cache is still one per line and in step with the
    /// document.
    pub fn invalidate(self: *TextView) void {
        for (self.lines.items) |*entry| entry.shaped = false;
    }

    fn splice(self: *TextView, edit: Edit) !void {
        // Nothing has been laid out yet, so there is nothing to keep in step.
        if (self.lines.items.len == 0) return;
        try spliceLines(self.gpa, &self.lines, edit.line, edit.removed, edit.added);
    }
};

/// Brings the cache back into step after an edit, told which line it landed in,
/// how many after it stopped existing, and how many came into being.
///
/// Every other entry survives untouched: a line that moved down the screen is
/// the same shaped line at a different baseline, which is why its glyphs are
/// kept in coordinates of their own.
///
/// Apart from `TextView` so it can be tested without a document to splice.
fn spliceLines(
    gpa: std.mem.Allocator,
    cache: *std.ArrayList(LineLayout),
    line: usize,
    removed: usize,
    added: usize,
) !void {
    const first = line + 1;
    std.debug.assert(first + removed <= cache.items.len);

    // Reserved before anything moves, so a failure cannot leave the cache a
    // different length from the document it describes.
    try cache.ensureUnusedCapacity(gpa, added);

    for (cache.items[first..][0..removed]) |*entry| {
        entry.sprites.deinit(gpa);
        entry.carets.deinit(gpa);
    }
    std.mem.copyForwards(LineLayout, cache.items[first..], cache.items[first + removed ..]);
    cache.items.len -= removed;

    cache.items.len += added;
    std.mem.copyBackwards(
        LineLayout,
        cache.items[first + added ..],
        cache.items[first .. cache.items.len - added],
    );
    for (cache.items[first..][0..added]) |*entry| entry.* = .{};

    // The line the edit landed in kept its place and lost its text.
    cache.items[line].shaped = false;
}

/// Four lines, each holding a sprite and a caret, so that dropping an entry
/// without freeing it shows up as a leak rather than as nothing at all.
fn testCache(gpa: std.mem.Allocator) !std.ArrayList(LineLayout) {
    var cache: std.ArrayList(LineLayout) = .empty;
    for ([_]usize{ 10, 20, 30, 40 }) |bytes| {
        var entry: LineLayout = .{ .bytes = bytes, .shaped = true };
        try entry.sprites.append(gpa, .{ .dest = .{ 0, 0 }, .source = .{ 0, 0 }, .size = .{ 1, 1 } });
        try entry.carets.append(gpa, .{ .offset = 0, .x = 0 });
        try cache.append(gpa, entry);
    }
    return cache;
}

fn testFree(gpa: std.mem.Allocator, cache: *std.ArrayList(LineLayout)) void {
    for (cache.items) |*entry| {
        entry.sprites.deinit(gpa);
        entry.carets.deinit(gpa);
    }
    cache.deinit(gpa);
}

test "an edit inside one line leaves every other line's layout alone" {
    const gpa = std.testing.allocator;
    var cache = try testCache(gpa);
    defer testFree(gpa, &cache);

    try spliceLines(gpa, &cache, 1, 0, 0);

    try std.testing.expectEqual(4, cache.items.len);
    try std.testing.expectEqualSlices(usize, &.{ 10, 20, 30, 40 }, &.{
        cache.items[0].bytes, cache.items[1].bytes, cache.items[2].bytes, cache.items[3].bytes,
    });
    try std.testing.expectEqualSlices(bool, &.{ true, false, true, true }, &.{
        cache.items[0].shaped, cache.items[1].shaped, cache.items[2].shaped, cache.items[3].shaped,
    });
}

test "splitting a line shifts the ones below it without reshaping them" {
    const gpa = std.testing.allocator;
    var cache = try testCache(gpa);
    defer testFree(gpa, &cache);

    // A newline typed into line 1.
    try spliceLines(gpa, &cache, 1, 0, 1);

    try std.testing.expectEqual(5, cache.items.len);
    try std.testing.expect(!cache.items[1].shaped);
    try std.testing.expect(!cache.items[2].shaped);
    // Lines 2 and 3 are the same shaped lines, one index further down.
    try std.testing.expectEqual(30, cache.items[3].bytes);
    try std.testing.expect(cache.items[3].shaped);
    try std.testing.expectEqual(40, cache.items[4].bytes);
    try std.testing.expect(cache.items[4].shaped);
}

test "joining two lines drops one entry and reshapes the survivor" {
    const gpa = std.testing.allocator;
    var cache = try testCache(gpa);
    defer testFree(gpa, &cache);

    // Backspace at the start of line 2, joining it onto line 1.
    try spliceLines(gpa, &cache, 1, 1, 0);

    try std.testing.expectEqual(3, cache.items.len);
    try std.testing.expectEqual(10, cache.items[0].bytes);
    try std.testing.expect(!cache.items[1].shaped);
    try std.testing.expectEqual(40, cache.items[2].bytes);
    try std.testing.expect(cache.items[2].shaped);
}

test "deleting across lines collapses them onto the one the edit started in" {
    const gpa = std.testing.allocator;
    var cache = try testCache(gpa);
    defer testFree(gpa, &cache);

    try spliceLines(gpa, &cache, 0, 3, 0);

    try std.testing.expectEqual(1, cache.items.len);
    try std.testing.expect(!cache.items[0].shaped);
}

/// Where line `index` sits, before rounding.
///
/// A function of the index rather than a running total, so a line lands in the
/// same place whatever else was drawn. Adding `line_height` repeatedly from the
/// first line on screen answers differently from adding it from line zero --
/// float addition does not associate -- and the two can fall either side of a
/// `@round`, which is a line jumping a pixel according to where it was scrolled
/// from.
fn lineTop(index: usize, top: f32, scroll: f32, line_height: f32) f32 {
    return top - scroll + @as(f32, @floatFromInt(index)) * line_height;
}

/// The lines that intersect a viewport `height` tall, as a half-open range.
fn visibleLines(
    top: f32,
    scroll: f32,
    height: f32,
    line_height: f32,
    count: usize,
) struct { first: usize, last: usize } {
    // `lineTop(i) + line_height > 0` and `lineTop(i) < height`, solved for i.
    // Ceil rather than `@floor(..) + 1`, which is one too many whenever the
    // division comes out even -- for a window of no height, a line drawn out of
    // nothing.
    const above = scroll - top;
    const first = clampIndex(@floor(above / line_height), count);
    const last = clampIndex(@ceil((above + height) / line_height), count);
    return .{ .first = first, .last = @max(first, last) };
}

/// Where the scrollbar's thumb goes, in pixels down the window.
const Thumb = struct { y: f32, height: f32 };

/// The thumb for a scroll of `scroll` through a document `content` tall, in a
/// track `height` tall.
///
/// The track stands for the document and nothing else, so the thumb is the
/// window's share of it and sits where the window sits. Scrolling past the last
/// line therefore carries the thumb below the track, where it is clipped -- which
/// is what being past the end looks like, and truer than counting empty space as
/// something there is to scroll through.
fn thumb(scroll: f32, content: f32, height: f32, minimum: f32) Thumb {
    // An empty document is not a thing to be a share of.
    if (content <= 0) return .{ .y = 0, .height = height };
    const share = height / content;
    return .{
        .y = @round(scroll * share),
        // Short of the minimum there is nothing to catch hold of, and a long
        // document would take it there.
        .height = @min(height, @max(minimum, @round(height * share))),
    };
}

test "the thumb is the window's share of the document" {
    // A document twice the window: half the track, at the top.
    const t = thumb(0, 200, 100, 10);
    try std.testing.expectEqual(@as(f32, 0), t.y);
    try std.testing.expectEqual(@as(f32, 50), t.height);
}

test "the thumb reaches the bottom when the last line does" {
    // Scrolled so the document's end meets the window's, the thumb's end meets
    // the track's: 100 of 200 scrolled, half a track tall, half way down.
    const t = thumb(100, 200, 100, 10);
    try std.testing.expectEqual(@as(f32, 50), t.y);
    try std.testing.expectEqual(@as(f32, 50), t.height);
}

test "scrolling past the last line carries the thumb below the track" {
    // The overscroll is not part of the document, so the thumb keeps going and
    // is clipped rather than being squeezed to make room for empty space.
    const t = thumb(160, 200, 100, 10);
    try std.testing.expectEqual(@as(f32, 80), t.y);
    try std.testing.expect(t.y + t.height > 100);
}

test "a document shorter than the window fills the track" {
    try std.testing.expectEqual(@as(f32, 100), thumb(0, 40, 100, 10).height);
}

test "a long document stops shrinking the thumb at the minimum" {
    try std.testing.expectEqual(@as(f32, 24), thumb(0, 1_000_000, 100, 24).height);
}

/// Where the scroll has to move to put line `index` down the middle of the
/// window, or the scroll it was given when the line is already on screen.
///
/// The middle rather than whichever edge it went behind: typing somewhere the
/// view had left behind wants what is around it, and an edge shows half of that.
fn scrollToCentre(scroll: f32, index: usize, top: f32, height: f32, line_height: f32) f32 {
    const y = lineTop(index, top, scroll, line_height);
    if (y >= 0 and y + line_height <= height) return scroll;
    return @round(scroll + y - (height - line_height) / 2);
}

/// A line number that arithmetic produced, brought into `[0, count]` before it
/// becomes an integer. `@intFromFloat` is undefined outside the range of what it
/// converts to, and nothing bounds this but the size of the window.
fn clampIndex(value: f32, count: usize) usize {
    // Negated so that a NaN, which compares false whichever way it is asked,
    // lands here rather than on a conversion that has no answer for it.
    if (!(value > 0)) return 0;
    const limit: f32 = @floatFromInt(count);
    if (value >= limit) return count;
    return @intFromFloat(value);
}

test "a viewport taller than the document shows all of it" {
    const range = visibleLines(10, 0, 1000, 15, 4);
    try std.testing.expectEqual(@as(usize, 0), range.first);
    try std.testing.expectEqual(@as(usize, 4), range.last);
}

test "a viewport shorter than the document stops short of its end" {
    // Lines of 15 starting 10 down, so the sixth begins at 85 and the seventh
    // at 100, which is already the bottom edge.
    try std.testing.expectEqual(@as(usize, 6), visibleLines(10, 0, 100, 15, 10).last);
}

test "a line beginning exactly at the bottom edge is not drawn" {
    // Lines of 15 from 0: the fourth begins at 45, which is the edge itself.
    // The `@floor(..) + 1` spelling answers 4 here.
    try std.testing.expectEqual(@as(usize, 3), visibleLines(0, 0, 45, 15, 10).last);
}

test "a window with no height draws nothing" {
    const range = visibleLines(0, 0, 0, 15, 10);
    try std.testing.expectEqual(range.first, range.last);
}

test "a margin taller than the window leaves room for nothing" {
    const range = visibleLines(60, 0, 40, 15, 10);
    try std.testing.expectEqual(range.first, range.last);
}

test "scrolling a whole line past the top drops exactly that line" {
    try std.testing.expectEqual(@as(usize, 1), visibleLines(0, 15, 100, 15, 10).first);
}

test "a line scrolled half out of view is still drawn" {
    try std.testing.expectEqual(@as(usize, 0), visibleLines(0, 7, 100, 15, 10).first);
}

test "the lines either side of the range are the ones off screen" {
    // The property the arithmetic exists for, rather than worked answers: at
    // every offset, everything in the range touches the window and its two
    // neighbours do not.
    const top = 5;
    const height = 97;
    const line_height = 15.2;
    const count = 400;

    var scroll: f32 = 0;
    while (scroll <= 600) : (scroll += 3) {
        const range = visibleLines(top, scroll, height, line_height, count);

        if (range.first > 0) {
            const before = lineTop(range.first - 1, top, scroll, line_height);
            try std.testing.expect(before + line_height <= 0);
        }
        if (range.last < count) {
            const after = lineTop(range.last, top, scroll, line_height);
            try std.testing.expect(after >= height);
        }

        var index = range.first;
        while (index < range.last) : (index += 1) {
            const y = lineTop(index, top, scroll, line_height);
            try std.testing.expect(y < height and y + line_height > 0);
        }
    }
}

test "scrollToCentre leaves a line that is already on screen alone" {
    try std.testing.expectEqual(@as(f32, 40), scrollToCentre(40, 4, 0, 100, 15));
}

test "scrollToCentre brings a line above the window to the middle" {
    // Scrolled 40, line 1 sits 25 above the window. The middle of 100 starts at
    // 42.5, so it asks for 40 - 25 - 42.5, rounded away from zero. The caller
    // clamps that back to the top of the document.
    try std.testing.expectEqual(@as(f32, -28), scrollToCentre(40, 1, 0, 100, 15));
}

test "scrollToCentre brings a line below the window to the middle" {
    // Line 20 spans 300 to 315, and centring it asks for 300 - 42.5.
    try std.testing.expectEqual(@as(f32, 258), scrollToCentre(0, 20, 0, 100, 15));
}

test "scrollToCentre lands on whole pixels and asks for somewhere on screen" {
    const line_height = 15.2;
    const top = 5;
    const height = 97;

    var index: usize = 0;
    while (index < 40) : (index += 1) {
        var scroll: f32 = 0;
        while (scroll <= 600) : (scroll += 7) {
            const want = scrollToCentre(scroll, index, top, height, line_height);
            try std.testing.expectEqual(want, @round(want));

            // Where it asks to be is fully inside the window; the caller
            // clamping the answer can only push it towards an edge.
            const y = lineTop(index, top, want, line_height);
            try std.testing.expect(y >= 0);
            try std.testing.expect(y + line_height <= height);
        }
    }
}

/// How far along a line the caret sits, given an offset into it.
///
/// Cluster boundaries are not character boundaries: `ffi` covers three bytes, so
/// the characters inside it have no boundary of their own. An offset landing
/// there divides the cluster's width across its bytes -- an approximation that
/// stops being reachable once the cursor moves by graphemes.
fn caretX(carets: []const Caret, offset: usize) f32 {
    // Shaping always leaves the end of the line, even for an empty one.
    std.debug.assert(carets.len > 0);
    std.debug.assert(offset <= carets[carets.len - 1].offset);

    var low: usize = 0;
    var high: usize = carets.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (carets[mid].offset <= offset) low = mid + 1 else high = mid;
    }

    // The first boundary is at offset 0, so something always matched.
    const at = carets[low - 1];
    if (at.offset == offset) return at.x;

    const next = carets[low];
    const into: f32 = @floatFromInt(offset - at.offset);
    const across: f32 = @floatFromInt(next.offset - at.offset);
    return at.x + (next.x - at.x) * into / across;
}

/// Which offset in a line a click at `target` means.
///
/// Nearest boundary rather than the one before, so clicking the right half of a
/// character puts the caret after it. Getting it wrong is not subtle: every
/// click would feel one character behind.
fn caretOffset(carets: []const Caret, target: f32) usize {
    std.debug.assert(carets.len > 0);

    // Sorted by x because the pen only moves right: shaping is left to right
    // and there is no bidi pass.
    var low: usize = 0;
    var high: usize = carets.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (carets[mid].x < target) low = mid + 1 else high = mid;
    }

    if (low == carets.len) return carets[carets.len - 1].offset;
    if (low == 0) return carets[0].offset;

    const before = carets[low - 1];
    const after = carets[low];
    return if (target - before.x < after.x - target) before.offset else after.offset;
}

/// What `shapeLine` leaves for "off ice": one boundary per character, except
/// across the ligature, which covers three bytes and has none inside it.
const test_carets = [_]Caret{
    .{ .offset = 0, .x = 0 },
    .{ .offset = 1, .x = 10 },
    .{ .offset = 2, .x = 25 },
    .{ .offset = 3, .x = 32 },
    .{ .offset = 4, .x = 62 },
    .{ .offset = 7, .x = 92 },
    .{ .offset = 8, .x = 100 },
};

test "an offset on a boundary is placed exactly on it" {
    try std.testing.expectEqual(@as(f32, 0), caretX(&test_carets, 0));
    try std.testing.expectEqual(@as(f32, 32), caretX(&test_carets, 3));
    try std.testing.expectEqual(@as(f32, 92), caretX(&test_carets, 7));
    // The end of the line is a boundary like any other.
    try std.testing.expectEqual(@as(f32, 100), caretX(&test_carets, 8));
}

test "an offset inside a ligature is placed across its width" {
    // Bytes 4, 5 and 6 are one glyph 30 wide, so its width is divided.
    try std.testing.expectEqual(@as(f32, 72), caretX(&test_carets, 5));
    try std.testing.expectEqual(@as(f32, 82), caretX(&test_carets, 6));
}

test "an empty line puts the caret at its start" {
    const carets = [_]Caret{.{ .offset = 0, .x = 0 }};
    try std.testing.expectEqual(@as(f32, 0), caretX(&carets, 0));
}

test "clicking takes the nearer boundary, not the one before" {
    // The first character spans 0 to 10, so its middle is the deciding point.
    try std.testing.expectEqual(1, caretOffset(&test_carets, 5.1));
    try std.testing.expectEqual(0, caretOffset(&test_carets, 4.9));
}

test "clicking inside a ligature cannot land in the middle of it" {
    // Two thirds of the way through, and still one of its two ends.
    try std.testing.expectEqual(7, caretOffset(&test_carets, 82));
    try std.testing.expectEqual(4, caretOffset(&test_carets, 70));
}

test "clicking off the end of a line lands at the end nearest the click" {
    try std.testing.expectEqual(8, caretOffset(&test_carets, 400));
    try std.testing.expectEqual(0, caretOffset(&test_carets, -400));
}

test "the two directions agree at every boundary" {
    for (test_carets) |caret| {
        try std.testing.expectEqual(caret.offset, caretOffset(&test_carets, caretX(&test_carets, caret.offset)));
    }
}

test {
    // Tests follow the imports: this file pulls in the document's, so a test
    // build reaches them without `main` having to know they exist.
    _ = @import("./document.zig");
    _ = @import("./painter.zig");
}
