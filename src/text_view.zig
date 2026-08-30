//! A view of a document: the text, where the caret sits in it, and the shaped
//! layout of every line.
//!
//! The layout cache lives here rather than with the atlas because it belongs to
//! a view rather than to a font. One atlas serves every document; each view of
//! one caches its own lines. Holding the document beside the cache is also what
//! makes them impossible to get out of step -- an edit and the splice that
//! answers it are one call, not two that a caller has to remember to pair.

const std = @import("std");

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
pub const bar_gutter = bar_inset + bar_width;

/// The shortest the thumb is allowed to get. A long document would otherwise
/// scale it down to something there is no catching with a pointer.
const bar_minimum = 24;

/// One array rather than two: the quads reach the GPU as a single buffer and are
/// drawn by index into it, so the split is where the colour changes rather than
/// where the memory does.
pub const Frame = struct {
    quads: []const Sprite,
    /// After every glyph, so it draws over the one it sits beside.
    caret: u32,
    /// After the caret. Both are drawn by the pipeline that samples nothing.
    bar: u32,
};

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

    /// The frame's glyphs, placed on screen. Cleared rather than freed between
    /// frames: it settles at the size of a screenful and stops allocating,
    /// which is what keeps a redraw free of the allocator.
    sprites: std.ArrayList(Sprite) = .empty,

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
        self.sprites.deinit(self.gpa);
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

    /// Moves the view by `pixels`, keeping the offset a whole number of them.
    /// What is left over waits for the next event rather than rounding away.
    pub fn scrollBy(self: *TextView, pixels: f32, atlas: *const GlyphAtlas, top: f32) void {
        self.pending += pixels;
        const whole = @trunc(self.pending);
        self.pending -= whole;
        self.scrollTo(self.scroll + whole, atlas, top);
    }

    /// Where the scrollbar's thumb sits in a window `height` tall.
    pub fn scrollbar(self: *const TextView, atlas: *const GlyphAtlas, top: f32, height: f32) Thumb {
        const count: f32 = @floatFromInt(self.document.lineCount());
        return thumb(self.scroll, top + count * atlas.line_height, height, @round(bar_minimum * atlas.scale));
    }

    /// Brings the caret's line into view, and clears the flag that asked for it.
    pub fn scrollToCaret(self: *TextView, atlas: *const GlyphAtlas, top: f32, height: f32) void {
        self.follow_caret = false;
        const index = self.document.lineAt(self.cursor);
        // A jump is not a gesture, so anything a gesture had part-way through
        // it goes rather than being applied on top of the answer.
        self.pending = 0;
        self.scrollTo(scrollToCentre(self.scroll, index, top, height, atlas.line_height), atlas, top);
    }

    fn scrollTo(self: *TextView, to: f32, atlas: *const GlyphAtlas, top: f32) void {
        self.scroll = @min(self.furthest(atlas, top), @max(0, to));
    }

    /// The far end of the scroll: where the last line reaches the top of the
    /// window rather than the bottom, so the end of a file stops being somewhere
    /// the view cannot follow you to. A document shorter than the window scrolls
    /// by the same rule.
    fn furthest(self: *const TextView, atlas: *const GlyphAtlas, top: f32) f32 {
        const last = self.document.lineCount() -| 1;
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
    pub fn layout(self: *TextView, atlas: *GlyphAtlas, origin: [2]f32, height: f32) !Frame {
        const x = origin[0];
        const top = origin[1];
        // Cached glyphs are placed by adding whole pixels. A fractional origin
        // would change which subpixel variant each one points at, and the cache
        // would be answering the wrong question.
        std.debug.assert(x == @round(x));
        std.debug.assert(self.scroll == @round(self.scroll));

        self.sprites.clearRetainingCapacity();
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

            const baseline = @round(lineTop(index, top, self.scroll, atlas.line_height) + atlas.ascent);
            try self.sprites.ensureUnusedCapacity(self.gpa, entry.sprites.items.len);
            for (entry.sprites.items) |sprite| {
                self.sprites.appendAssumeCapacity(.{
                    .dest = .{ sprite.dest[0] + x, sprite.dest[1] + baseline },
                    .source = sprite.source,
                    .size = sprite.size,
                });
            }

            if (index == caret_line) caret = self.caretOn(atlas, entry, index, x, baseline);
        }

        // The caret can be outside the range drawn, above it or below it. Its
        // quad is built anyway, out where the GPU discards it, because `present`
        // draws one unconditionally. Nothing partly on screen reaches here, so
        // where exactly it lands does not matter.
        if (caret == null) {
            const entry = &self.lines.items[caret_line];
            if (!entry.shaped) try atlas.shapeLine(try self.document.lineSlice(caret_line), entry);
            std.debug.assert(entry.bytes == self.document.lineLength(caret_line));

            const off = lineTop(caret_line, top, self.scroll, atlas.line_height) + atlas.ascent;
            caret = self.caretOn(atlas, entry, caret_line, x, @round(off));
        }
        // Last, so it draws over the glyph it sits beside, and so its own
        // colour is a second draw over the tail rather than a per-glyph field.
        try self.sprites.append(self.gpa, caret.?);
        const caret_at: u32 = @intCast(self.sprites.items.len - 1);

        const t = self.scrollbar(atlas, top, height);
        try self.sprites.append(self.gpa, .solid(
            .{ @round(bar_inset * atlas.scale), t.y },
            .{ @round(bar_width * atlas.scale), t.height },
        ));

        return .{
            .quads = self.sprites.items,
            .caret = caret_at,
            .bar = @intCast(self.sprites.items.len - 1),
        };
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
    pub fn moveCaretTo(self: *TextView, atlas: *GlyphAtlas, x: f32, top: f32, point: [2]f32) !void {
        // Nothing has been laid out, so there is nothing on screen to click.
        if (self.lines.items.len == 0) return;

        const row = (point[1] - top + self.scroll) / atlas.line_height;
        const index = if (row < 0)
            0
        else
            @min(self.document.lineCount() - 1, @as(usize, @intFromFloat(row)));

        // A click lands on a line that was drawn, but the row arithmetic
        // clamps, and what it clamps to need not have been.
        const entry = &self.lines.items[index];
        if (!entry.shaped) try atlas.shapeLine(try self.document.lineSlice(index), entry);

        self.cursor = self.document.lineStart(index) + caretOffset(entry.carets.items, point[0] - x);
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
pub const Thumb = struct { y: f32, height: f32 };

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

/// What an edit did to the line index, so anything else keyed by line can be
/// spliced rather than rebuilt. Both counts are of lines after `line`.
const Edit = struct {
    /// The line the edit landed in. Its bytes changed; no other line's did.
    line: usize,
    /// Lines that stopped existing, their newlines having been deleted.
    removed: usize,
    /// Lines that came into being, from newlines in the inserted text.
    added: usize,
};

/// Room left ahead of the text by a reallocation. Typing arrives one character
/// at a time, and an exact fit would reallocate on every keystroke.
const min_gap = 4096;

/// The document: one contiguous allocation with a hole in it, kept wherever the
/// last edit happened.
///
/// Editing at the hole is a write and a bounds change. Editing elsewhere moves
/// the hole there first, one memmove of the bytes in between. The bet is that
/// editing is local, so a jump across the whole file is a rare pass at memory
/// bandwidth rather than a data structure to maintain.
const Buffer = struct {
    gpa: std.mem.Allocator,

    /// Text and hole together. `bytes[0..gap_start]` and `bytes[gap_end..]` are
    /// the document; what lies between them is not part of it.
    bytes: []u8,
    gap_start: usize,
    gap_end: usize,

    /// Where each line begins, counting the gap as absent. Variable-length lines
    /// in a proportional font cannot be found by arithmetic, so they are indexed,
    /// and the index is patched on each edit rather than rebuilt. Text ending in
    /// a newline therefore ends with an empty line.
    starts: std.ArrayList(usize),

    /// A line containing the gap is not contiguous and has to be copied out.
    /// Only one line can contain it, so one scratch buffer serves all of them.
    scratch: std.ArrayList(u8) = .empty,

    fn init(gpa: std.mem.Allocator, text: []const u8) !Buffer {
        var self: Buffer = .{
            .gpa = gpa,
            .bytes = try gpa.alloc(u8, text.len + min_gap),
            .gap_start = text.len,
            .gap_end = text.len + min_gap,
            .starts = .empty,
        };
        errdefer self.deinit();

        @memcpy(self.bytes[0..text.len], text);

        try self.starts.append(gpa, 0);
        for (text, 0..) |byte, offset| {
            if (byte == '\n') try self.starts.append(gpa, offset + 1);
        }

        return self;
    }

    fn deinit(self: *Buffer) void {
        self.scratch.deinit(self.gpa);
        self.starts.deinit(self.gpa);
        self.gpa.free(self.bytes);
    }

    fn byteLen(self: *const Buffer) usize {
        return self.bytes.len - (self.gap_end - self.gap_start);
    }

    fn lineCount(self: *const Buffer) usize {
        return self.starts.items.len;
    }

    /// Inserts `text` so that its first byte lands at `at`.
    fn insert(self: *Buffer, at: usize, text: []const u8) !Edit {
        std.debug.assert(at <= self.byteLen());
        const line = self.lineAt(at);
        if (text.len == 0) return .{ .line = line, .removed = 0, .added = 0 };

        // Both allocations happen before a byte is written, so failing here
        // leaves the document and its index exactly as they were.
        const added = std.mem.count(u8, text, "\n");
        try self.starts.ensureUnusedCapacity(self.gpa, added);
        if (self.gap_end - self.gap_start < text.len) try self.grow(text.len);

        self.moveGap(at);
        @memcpy(self.bytes[self.gap_start..][0..text.len], text);
        self.gap_start += text.len;

        self.reindexInsert(line, at, text, added);
        return .{ .line = line, .removed = 0, .added = added };
    }

    /// Deletes the `count` bytes starting at `at`. Cannot fail: the text stays
    /// where it is and the hole grows over it.
    fn delete(self: *Buffer, at: usize, count: usize) Edit {
        std.debug.assert(at + count <= self.byteLen());
        const line = self.lineAt(at);
        if (count == 0) return .{ .line = line, .removed = 0, .added = 0 };

        self.moveGap(at);
        self.gap_end += count;

        return .{ .line = line, .removed = self.reindexDelete(line, at, count), .added = 0 };
    }

    /// Line `index` without its newline. The result borrows from the buffer and
    /// is good until the next edit.
    fn lineSlice(self: *Buffer, index: usize) ![]const u8 {
        std.debug.assert(index < self.lineCount());
        const from = self.starts.items[index];
        const to = if (index + 1 < self.lineCount())
            self.starts.items[index + 1] - 1
        else
            self.byteLen();
        return self.slice(from, to);
    }

    /// Turns an offset within a line, which is what layout and hit-testing both
    /// speak in, back into one the document understands.
    fn lineStart(self: *const Buffer, index: usize) usize {
        std.debug.assert(index < self.lineCount());
        return self.starts.items[index];
    }

    /// Without reading it. A cached line is never fetched, so this is what
    /// checks the cache still lines up with the document.
    fn lineLength(self: *const Buffer, index: usize) usize {
        std.debug.assert(index < self.lineCount());
        const from = self.starts.items[index];
        const to = if (index + 1 < self.lineCount())
            self.starts.items[index + 1] - 1
        else
            self.byteLen();
        return to - from;
    }

    /// The offset one character before `offset`, or `offset` at the start of the
    /// document.
    ///
    /// A whole UTF-8 sequence, but not yet a whole grapheme cluster: `e` plus a
    /// combining acute is two of these, so backspacing over it takes two presses.
    /// Fixing that needs Unicode tables, and is not worth the dependency until
    /// cursor movement exists to be wrong about.
    fn stepBack(self: *const Buffer, offset: usize) usize {
        var at = offset;
        while (at > 0) {
            at -= 1;
            // Continuation bytes are 10xxxxxx.
            if (self.byteAt(at) & 0xc0 != 0x80) break;
        }
        return at;
    }

    fn byteAt(self: *const Buffer, offset: usize) u8 {
        std.debug.assert(offset < self.byteLen());
        const gap = self.gap_end - self.gap_start;
        return if (offset < self.gap_start) self.bytes[offset] else self.bytes[offset + gap];
    }

    /// The last line starting at or before `offset`. Binary search, because an
    /// edit and a mouse click both need it and neither knows it already.
    fn lineAt(self: *const Buffer, offset: usize) usize {
        var low: usize = 0;
        var high: usize = self.starts.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.starts.items[mid] <= offset) low = mid + 1 else high = mid;
        }
        // Line 0 starts at 0, so something always matched.
        return low - 1;
    }

    /// `[from, to)` as one slice, copying it out when the gap divides it.
    fn slice(self: *Buffer, from: usize, to: usize) ![]const u8 {
        const gap = self.gap_end - self.gap_start;
        if (to <= self.gap_start) return self.bytes[from..to];
        if (from >= self.gap_start) return self.bytes[from + gap .. to + gap];

        self.scratch.clearRetainingCapacity();
        try self.scratch.appendSlice(self.gpa, self.bytes[from..self.gap_start]);
        try self.scratch.appendSlice(self.gpa, self.bytes[self.gap_end .. to + gap]);
        return self.scratch.items;
    }

    /// Moves the bytes in between across the hole. The one operation here that
    /// is not constant time, and what an edit away from the last one costs.
    fn moveGap(self: *Buffer, to: usize) void {
        std.debug.assert(to <= self.byteLen());
        if (to == self.gap_start) return;

        if (to < self.gap_start) {
            const moved = self.bytes[to..self.gap_start];
            std.mem.copyBackwards(u8, self.bytes[self.gap_end - moved.len ..], moved);
            self.gap_end -= moved.len;
            self.gap_start = to;
        } else {
            const count = to - self.gap_start;
            const moved = self.bytes[self.gap_end..][0..count];
            std.mem.copyForwards(u8, self.bytes[self.gap_start..][0..count], moved);
            self.gap_start += count;
            self.gap_end += count;
        }
    }

    /// Reallocates with a hole of at least `needed`, left where it already is.
    fn grow(self: *Buffer, needed: usize) !void {
        const tail = self.bytes.len - self.gap_end;
        const capacity = self.byteLen() + @max(needed, min_gap);

        self.bytes = try self.gpa.realloc(self.bytes, capacity);
        const gap_end = capacity - tail;
        std.mem.copyBackwards(u8, self.bytes[gap_end..], self.bytes[self.gap_end..][0..tail]);
        self.gap_end = gap_end;
    }

    /// Line starts after an insertion shift along by its length, and every
    /// newline inside it begins a line. `added` is counted by the caller so the
    /// room could be reserved before anything was written.
    fn reindexInsert(self: *Buffer, line: usize, at: usize, text: []const u8, added: usize) void {
        const starts = &self.starts;
        // Line starts at exactly `at` do not move: text inserted there becomes
        // the beginning of that line rather than the end of the one before.
        const after = line + 1;

        // One shift for all the new lines: one each would make pasting a block
        // quadratic in its line count.
        starts.items.len += added;
        std.mem.copyBackwards(
            usize,
            starts.items[after + added ..],
            starts.items[after .. starts.items.len - added],
        );
        for (starts.items[after + added ..]) |*start| start.* += text.len;

        var next = after;
        for (text, 0..) |byte, offset| {
            if (byte != '\n') continue;
            starts.items[next] = at + offset + 1;
            next += 1;
        }
    }

    /// A line start in `(at, at + count]` had its newline deleted, so it stops
    /// being a line; what follows shifts back. Answers how many were lost.
    fn reindexDelete(self: *Buffer, line: usize, at: usize, count: usize) usize {
        const starts = &self.starts;
        const first = line + 1;

        var last = first;
        while (last < starts.items.len and starts.items[last] <= at + count) last += 1;

        std.mem.copyForwards(usize, starts.items[first..], starts.items[last..]);
        starts.items.len -= last - first;

        for (starts.items[first..]) |*start| start.* -= count;
        return last - first;
    }
};

test "an empty document is one empty line" {
    var buffer = try Buffer.init(std.testing.allocator, "");
    defer buffer.deinit();

    try std.testing.expectEqual(0, buffer.byteLen());
    try std.testing.expectEqual(1, buffer.lineCount());
    try std.testing.expectEqualStrings("", try buffer.lineSlice(0));
}

test "initial text is indexed into lines" {
    var buffer = try Buffer.init(std.testing.allocator, "one\ntwo\nthree");
    defer buffer.deinit();

    try std.testing.expectEqual(13, buffer.byteLen());
    try std.testing.expectEqualSlices(usize, &.{ 0, 4, 8 }, buffer.starts.items);
    try std.testing.expectEqualStrings("one", try buffer.lineSlice(0));
    try std.testing.expectEqualStrings("two", try buffer.lineSlice(1));
    try std.testing.expectEqualStrings("three", try buffer.lineSlice(2));
}

test "text ending in a newline ends with an empty line" {
    var buffer = try Buffer.init(std.testing.allocator, "one\n");
    defer buffer.deinit();

    try std.testing.expectEqual(2, buffer.lineCount());
    try std.testing.expectEqualStrings("one", try buffer.lineSlice(0));
    try std.testing.expectEqualStrings("", try buffer.lineSlice(1));
}

test "inserting reads back through the gap it leaves behind" {
    var buffer = try Buffer.init(std.testing.allocator, "hello world");
    defer buffer.deinit();

    // Mid-line, so the gap ends up inside line 0 and reading it has to splice
    // the two halves back together.
    _ = try buffer.insert(5, ",");
    try std.testing.expectEqualStrings("hello, world", try buffer.lineSlice(0));

    _ = try buffer.insert(0, ">> ");
    _ = try buffer.insert(buffer.byteLen(), "!");
    try std.testing.expectEqualStrings(">> hello, world!", try buffer.lineSlice(0));
}

test "the gap moving back and forth does not disturb the text" {
    var buffer = try Buffer.init(std.testing.allocator, "abcdefghij");
    defer buffer.deinit();

    // Alternating ends, so every insert drags the gap across most of the text.
    _ = try buffer.insert(0, "1");
    _ = try buffer.insert(buffer.byteLen(), "2");
    _ = try buffer.insert(1, "3");
    _ = try buffer.insert(buffer.byteLen() - 1, "4");

    try std.testing.expectEqualStrings("13abcdefghij42", try buffer.lineSlice(0));
}

test "inserting a newline splits a line and shifts the ones after it" {
    var buffer = try Buffer.init(std.testing.allocator, "one\ntwo");
    defer buffer.deinit();

    _ = try buffer.insert(1, "\n");
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 5 }, buffer.starts.items);
    try std.testing.expectEqualStrings("o", try buffer.lineSlice(0));
    try std.testing.expectEqualStrings("ne", try buffer.lineSlice(1));
    try std.testing.expectEqualStrings("two", try buffer.lineSlice(2));
}

test "inserting at a line start belongs to that line, not the one before" {
    var buffer = try Buffer.init(std.testing.allocator, "one\ntwo");
    defer buffer.deinit();

    _ = try buffer.insert(4, "X");
    try std.testing.expectEqualSlices(usize, &.{ 0, 4 }, buffer.starts.items);
    try std.testing.expectEqualStrings("one", try buffer.lineSlice(0));
    try std.testing.expectEqualStrings("Xtwo", try buffer.lineSlice(1));
}

test "pasting several lines indexes all of them at once" {
    var buffer = try Buffer.init(std.testing.allocator, "start\nend");
    defer buffer.deinit();

    _ = try buffer.insert(6, "a\nb\nc\n");
    try std.testing.expectEqualSlices(usize, &.{ 0, 6, 8, 10, 12 }, buffer.starts.items);
    try std.testing.expectEqualStrings("start", try buffer.lineSlice(0));
    try std.testing.expectEqualStrings("a", try buffer.lineSlice(1));
    try std.testing.expectEqualStrings("b", try buffer.lineSlice(2));
    try std.testing.expectEqualStrings("c", try buffer.lineSlice(3));
    try std.testing.expectEqualStrings("end", try buffer.lineSlice(4));
}

test "deleting within a line leaves the index alone" {
    var buffer = try Buffer.init(std.testing.allocator, "one\ntwo\nthree");
    defer buffer.deinit();

    _ = buffer.delete(4, 2);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4, 6 }, buffer.starts.items);
    try std.testing.expectEqualStrings("o", try buffer.lineSlice(1));
    try std.testing.expectEqualStrings("three", try buffer.lineSlice(2));
}

test "deleting a newline joins the lines it separated" {
    var buffer = try Buffer.init(std.testing.allocator, "one\ntwo\nthree");
    defer buffer.deinit();

    _ = buffer.delete(3, 1);
    try std.testing.expectEqual(2, buffer.lineCount());
    try std.testing.expectEqualSlices(usize, &.{ 0, 7 }, buffer.starts.items);
    try std.testing.expectEqualStrings("onetwo", try buffer.lineSlice(0));
    try std.testing.expectEqualStrings("three", try buffer.lineSlice(1));
}

test "deleting across several lines removes every start inside the range" {
    var buffer = try Buffer.init(std.testing.allocator, "one\ntwo\nthree\nfour");
    defer buffer.deinit();

    // From the middle of line 0 to the middle of line 3.
    _ = buffer.delete(2, 14);
    try std.testing.expectEqual(1, buffer.lineCount());
    try std.testing.expectEqualStrings("onur", try buffer.lineSlice(0));
}

test "growing past the initial gap keeps both halves" {
    var buffer = try Buffer.init(std.testing.allocator, "head|tail");
    defer buffer.deinit();

    // Put the hole in the middle first. A new buffer keeps it at the end,
    // where reallocating has nothing behind it to carry across.
    _ = try buffer.insert(4, "!");

    // Longer than the hole in one go, so this reallocates rather than filling
    // what it was given.
    const filler = "x" ** (min_gap + 100);
    _ = try buffer.insert(2, filler);

    try std.testing.expectEqual(10 + filler.len, buffer.byteLen());
    const line = try buffer.lineSlice(0);
    try std.testing.expectEqualStrings("he", line[0..2]);
    try std.testing.expectEqualStrings("ad!|tail", line[line.len - 8 ..]);
}

test "moving a nearly exhausted gap a long way does not smear the text" {
    const head = "head";
    var buffer = try Buffer.init(std.testing.allocator, head);
    defer buffer.deinit();

    // Fill the hole to within a few bytes, without asking for more than it
    // holds and so without reallocating. The text then being dragged across it
    // is longer than the hole is, which is the only time the source and the
    // destination of the move overlap.
    const filler = "-" ** (min_gap - 4);
    _ = try buffer.insert(head.len, filler);

    _ = try buffer.insert(0, "<");
    _ = try buffer.insert(buffer.byteLen(), ">");

    const line = try buffer.lineSlice(0);
    try std.testing.expectEqual(head.len + filler.len + 2, line.len);
    try std.testing.expectEqualStrings("<head", line[0..5]);
    try std.testing.expectEqualStrings("-->", line[line.len - 3 ..]);
    for (line[5 .. line.len - 1]) |byte| try std.testing.expectEqual('-', byte);
}

test "only the line holding the gap is spliced out of scratch" {
    var buffer = try Buffer.init(std.testing.allocator, "one\ntwo\nthree");
    defer buffer.deinit();

    // Puts the gap inside line 1, so that one line is copied out while the
    // others point straight into the buffer.
    _ = try buffer.insert(5, "!");

    try std.testing.expectEqualStrings("one", try buffer.lineSlice(0));
    try std.testing.expectEqualStrings("t!wo", try buffer.lineSlice(1));
    try std.testing.expectEqualStrings("three", try buffer.lineSlice(2));

    try std.testing.expectEqual(3, buffer.lineLength(0));
    try std.testing.expectEqual(4, buffer.lineLength(1));
    try std.testing.expectEqual(5, buffer.lineLength(2));
}

test "stepping back moves over a character, not a byte" {
    var buffer = try Buffer.init(std.testing.allocator, "a\u{e9}\u{6f22}");
    defer buffer.deinit();

    // One byte, then two, then three.
    try std.testing.expectEqual(6, buffer.byteLen());
    try std.testing.expectEqual(3, buffer.stepBack(6));
    try std.testing.expectEqual(1, buffer.stepBack(3));
    try std.testing.expectEqual(0, buffer.stepBack(1));
    try std.testing.expectEqual(0, buffer.stepBack(0));
}

test "stepping back reads through the gap" {
    var buffer = try Buffer.init(std.testing.allocator, "ab");
    defer buffer.deinit();

    // Leaves the gap in the middle of the character it just wrote.
    _ = try buffer.insert(1, "\u{e9}");

    try std.testing.expectEqual(3, buffer.stepBack(4));
    try std.testing.expectEqual(1, buffer.stepBack(3));
    try std.testing.expectEqual(0, buffer.stepBack(1));
}

test "lineAt finds the line an offset falls on" {
    var buffer = try Buffer.init(std.testing.allocator, "one\ntwo\nthree");
    defer buffer.deinit();

    try std.testing.expectEqual(0, buffer.lineAt(0));
    try std.testing.expectEqual(0, buffer.lineAt(3));
    try std.testing.expectEqual(1, buffer.lineAt(4));
    try std.testing.expectEqual(1, buffer.lineAt(7));
    try std.testing.expectEqual(2, buffer.lineAt(8));
    try std.testing.expectEqual(2, buffer.lineAt(13));
}

test "random edits agree with a plain array doing the same thing" {
    const gpa = std.testing.allocator;
    const seed_text = "seed\ntext";

    var buffer = try Buffer.init(gpa, seed_text);
    defer buffer.deinit();

    // The same document held the obvious way, which is wrong for an editor and
    // right for saying what the answer should have been.
    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(gpa);
    try model.appendSlice(gpa, seed_text);

    var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);
    const random = prng.random();
    // Newlines at the edges and in the middle, since the index is where the
    // bugs would be.
    const words = [_][]const u8{ "a", "\n", "hello", "x\ny\nz", " ", "\n\n" };

    for (0..3000) |_| {
        const len = model.items.len;
        if (len == 0 or random.boolean()) {
            const at = random.uintAtMost(usize, len);
            const text = words[random.uintLessThan(usize, words.len)];
            _ = try buffer.insert(at, text);
            try model.insertSlice(gpa, at, text);
        } else {
            const at = random.uintLessThan(usize, len);
            const count = random.uintAtMost(usize, @min(len - at, 8));
            _ = buffer.delete(at, count);
            model.replaceRangeAssumeCapacity(at, count, "");
        }

        try std.testing.expectEqual(model.items.len, buffer.byteLen());

        var expected = std.mem.splitScalar(u8, model.items, '\n');
        var index: usize = 0;
        while (expected.next()) |line| : (index += 1) {
            try std.testing.expect(index < buffer.lineCount());
            try std.testing.expectEqualStrings(line, try buffer.lineSlice(index));
            try std.testing.expectEqual(line.len, buffer.lineLength(index));
        }
        try std.testing.expectEqual(index, buffer.lineCount());
    }
}
