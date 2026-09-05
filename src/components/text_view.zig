//! A view of a file: where the caret sits in it, how far down it is being
//! looked at, and the scrollbar that says so.
//!
//! Everything derived from the bytes -- the line index, the shaped layout of
//! every line, the caret, the scroll -- lives on the file (see open_file.zig).
//! A view is made on the spot from a file and the room it was given, and kept
//! nowhere, since there is nothing left in it to keep.

const std = @import("std");

const message_mod = @import("../message.zig");
const Message = message_mod.Message;
const painter_mod = @import("../painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const open_file = @import("../open_file.zig");
const Buffer = open_file.Buffer;
const OpenFile = open_file.OpenFile;
const Span = open_file.Span;
const drawLine = @import("../text.zig").draw;

const glyph_atlas = @import("../glyph_atlas.zig");
const Model = @import("../model.zig").Model;
const Caret = glyph_atlas.Caret;
const GlyphAtlas = glyph_atlas.GlyphAtlas;
const LineLayout = glyph_atlas.LineLayout;
const Sprite = glyph_atlas.Sprite;

/// Two rather than one so the caret does not thin to a hairline and vanish on a
/// dense display. Scaled with the text, like the rest below.
const caret_width = 2;

const bar_width = 8;
const bar_inset = 3;
const bar_gutter = bar_inset + bar_width;

/// The shortest the thumb is allowed to get, so a long file cannot scale it down
/// to nothing to catch with a pointer.
const bar_minimum = 24;

const text_margin: [2]f32 = .{ 5, 5 };

/// How much of a selected newline shows, so three selected lines do not read as
/// three separate pieces of text.
const newline_stub = 4;

/// Layers, so the selection sits under the text and the caret and scrollbar over
/// it: within a layer the painter reorders, so covering needs a layer of its own.
const select_key: Key = .{ .layer = 0, .pipeline = .solid, .colour = .text_selection };
const glyph_key: Key = .{ .layer = 1, .pipeline = .glyphs, .colour = .text };
const caret_key: Key = .{ .layer = 2, .pipeline = .solid, .colour = .caret };
const bar_key: Key = .{ .layer = 3, .pipeline = .solid, .colour = .scrollbar };

/// A file and the room it has been given, made on the spot and kept nowhere.
pub const TextView = struct {
    file: *OpenFile,
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    which: usize = 0,

    pub fn init(which: usize, file: *OpenFile, rect: Rect) TextView {
        return .{ .file = file, .rect = rect, .which = which };
    }

    /// What a raw pointer message means in this column, as a resolved message for
    /// `Model.update`. Pointer only: the window keeps the keyboard.
    pub fn resolve(self: *const TextView, model: *const Model, message: Message) Message {
        switch (message) {
            .wheel => |wheel| return self.scrollBy(model, wheel.delta),
            .press => |what| {
                // Asked first, so a press on the scrollbar moves the view.
                if (self.thumbGrab(model, what.at)) |grab| {
                    return .{ .grab = .{ .column = self.which, .at = grab } };
                }
                // Shift is not consulted: a double-click says what it wants.
                if (what.clicks >= 2) return self.chooseAt(model, what.at);

                return self.caretAt(model, what.at, what.extend);
            },
            .move => |at| {
                // Reached only while the pointer is held, so a hover cannot lay
                // down a selection.
                if (self.file.drag) |grab| return self.dragTo(model, at[1], grab);

                // Dragging out a selection. Unchanged is answered as nothing, so
                // wandering within one character costs no frame.
                const asked = self.caretAt(model, at, true);
                switch (asked) {
                    .caret => |where| if (where.at == self.file.cursor) return .none,
                    else => {},
                }
                return asked;
            },
            .release => return .{ .grab = .{ .column = self.which, .at = null } },
            .look => |at| return self.lookAt(model, at),
            else => return .none,
        }
    }

    /// Whole pixels: a fractional origin would change which subpixel variant
    /// every cached glyph points at.
    fn origin(self: *const TextView, model: *const Model) [2]f32 {
        return .{
            @round(self.rect.x + (bar_gutter + text_margin[0]) * model.atlas.scale),
            @round(self.rect.y + text_margin[1] * model.atlas.scale),
        };
    }

    /// Keeps the offset a whole number of pixels; the fraction left over rides
    /// along in the message rather than rounding away.
    fn scrollBy(self: *const TextView, model: *const Model, pixels: f32) Message {
        const gathered = self.file.pending + pixels;
        const whole = @trunc(gathered);
        return self.scrollTo(model, self.file.scroll + whole, gathered - whole);
    }

    /// Where the scrollbar's thumb sits in a window `height` tall.
    fn scrollbar(self: *const TextView, model: *const Model) Thumb {
        const count: f32 = @floatFromInt(self.file.buffer.lineCount());
        const content = self.origin(model)[1] - self.rect.y + count * model.atlas.line_height;
        return thumb(self.file.scroll, content, self.rect.height, @round(bar_minimum * model.atlas.scale));
    }

    /// Where on the thumb a press takes hold, or null when it missed the
    /// scrollbar. The whole gutter answers, not just the thumb's width; a press
    /// on the track takes hold of the thumb's middle, so it jumps to the pointer.
    fn thumbGrab(self: *const TextView, model: *const Model, point: [2]f32) ?f32 {
        const from_left = point[0] - self.rect.x;
        if (from_left < 0 or from_left >= @round(bar_gutter * model.atlas.scale)) return null;

        const t = self.scrollbar(model);
        const offset = point[1] - self.rect.y - t.y;
        if (offset < 0 or offset >= t.height) return t.height / 2;
        return offset;
    }

    /// Drags the thumb so that the point `grab` down it sits at `y`.
    fn dragTo(self: *const TextView, model: *const Model, y: f32, grab: f32) Message {
        if (self.rect.height <= 0) return .none;
        const count: f32 = @floatFromInt(self.file.buffer.lineCount());
        // The inverse of the thumb, whose top is `scroll * height / content`.
        const content = self.origin(model)[1] - self.rect.y + count * model.atlas.line_height;
        return self.scrollTo(model, @round((y - self.rect.y - grab) * content / self.rect.height), 0);
    }

    /// Fits the file to the room this column has -- the one thing no message can
    /// carry, since how far a file scrolls depends on a height nothing knew when
    /// the message arrived. `follow_caret` brings a caret gone off screen back.
    pub fn settle(self: *const TextView, model: *const Model) void {
        const file = self.file;
        if (file.follow_caret) {
            file.follow_caret = false;
            const index = file.buffer.lineAt(file.cursor);
            // A jump is not a gesture, so drop any fraction one had in flight.
            file.pending = 0;
            const top = self.origin(model)[1] - self.rect.y;
            file.scroll = scrollToCentre(file.scroll, index, top, self.rect.height, model.atlas.line_height);
        }
        file.scroll = @min(self.furthest(model), @max(0, file.scroll));

        // Worked out here because where the selection sits on screen is a
        // question only the settled scroll can answer.
        if (file.warp_caret) {
            file.warp_caret = false;
            file.warp_to = self.selectionPixel(model);
        }
    }

    /// The middle of the first line the selection covers, in window pixels: the
    /// middle, not an edge, so the click it invites cannot round to the character
    /// just outside and take a different word.
    fn selectionPixel(self: *const TextView, model: *const Model) [2]f32 {
        const file = self.file;
        const span = file.selected();
        const index = file.buffer.lineAt(span.from);
        const start = file.buffer.lineStart(index);
        const stop = start + file.buffer.lineLength(index);

        const at = self.origin(model);
        var x = at[0];
        if (index < file.lines.items.len) {
            const entry = &file.lines.items[index];
            const shaped = if (model.atlas.stale(entry)) shape: {
                const text = file.buffer.lineSlice(index) catch break :shape false;
                model.atlas.shapeLine(text, entry) catch break :shape false;
                break :shape true;
            } else true;
            if (shaped) {
                const left = caretX(entry.carets.items, span.from - start);
                const right = caretX(entry.carets.items, @min(span.to, stop) - start);
                x = at[0] + (left + right) / 2;
            }
        }

        const top = at[1] - self.rect.y;
        const line_top = self.rect.y + lineTop(index, top, file.scroll, model.atlas.line_height);
        return .{ @round(x), @round(line_top + model.atlas.line_height / 2) };
    }

    fn scrollTo(self: *const TextView, model: *const Model, to: f32, pending: f32) Message {
        const clamped = @min(self.furthest(model), @max(0, to));
        if (clamped == self.file.scroll and pending == self.file.pending) return .none;
        return .{ .scroll = .{ .column = self.which, .to = clamped, .pending = pending } };
    }

    /// The far end of the scroll: the last line reaching the top of the window
    /// rather than the bottom, so the end of a file is somewhere the view follows.
    fn furthest(self: *const TextView, model: *const Model) f32 {
        const last = self.file.buffer.lineCount() -| 1;
        const top = self.origin(model)[1] - self.rect.y;
        return @max(0, @ceil(top + @as(f32, @floatFromInt(last)) * model.atlas.line_height));
    }

    /// Places every visible line's glyphs, shaping only the ones gone stale since
    /// they were last seen.
    pub fn draw(self: *const TextView, model: *const Model, painter: *Painter) !void {
        // So a long line cannot run past the right edge into another column.
        painter.clipTo(self.rect);
        defer painter.clipTo(null);

        const at = self.origin(model);
        const x = at[0];
        const top = at[1] - self.rect.y;
        const height = self.rect.height;
        std.debug.assert(self.file.scroll == @round(self.file.scroll));

        const count = self.file.buffer.lineCount();
        if (self.file.lines.items.len == 0) try self.file.lines.appendNTimes(model.allocator, .{}, count);
        // Anything else means an edit did not reach the cache.
        std.debug.assert(self.file.lines.items.len == count);

        const caret_line = self.file.buffer.lineAt(self.file.cursor);
        var caret: ?Sprite = null;

        const range = visibleLines(top, self.file.scroll, height, model.atlas.line_height, count);
        for (self.file.lines.items[range.first..range.last], range.first..) |*entry, index| {
            if (model.atlas.stale(entry)) try model.atlas.shapeLine(try self.file.buffer.lineSlice(index), entry);
            std.debug.assert(entry.bytes == self.file.buffer.lineLength(index));

            const baseline = @round(self.rect.y + lineTop(index, top, self.file.scroll, model.atlas.line_height) + model.atlas.ascent);

            if (self.selectionOn(model, entry, index, x, baseline)) |band| {
                try painter.add(select_key, band);
            }
            try drawLine(painter, glyph_key, entry, .{ x, baseline });

            if (index == caret_line) caret = self.caretOn(model, entry, index, x, baseline);
        }

        // The caret may be off screen; its quad is added anyway, out where the
        // GPU discards it, so where it is never has to be a special case.
        if (caret == null) {
            const entry = &self.file.lines.items[caret_line];
            if (model.atlas.stale(entry)) try model.atlas.shapeLine(try self.file.buffer.lineSlice(caret_line), entry);
            std.debug.assert(entry.bytes == self.file.buffer.lineLength(caret_line));

            const off = self.rect.y + lineTop(caret_line, top, self.file.scroll, model.atlas.line_height) + model.atlas.ascent;
            caret = self.caretOn(model, entry, caret_line, x, @round(off));
        }
        try painter.add(caret_key, caret.?);

        const t = self.scrollbar(model);
        try painter.add(bar_key, .solid(
            .{ @round(self.rect.x + bar_inset * model.atlas.scale), self.rect.y + t.y },
            .{ @round(bar_width * model.atlas.scale), t.height },
        ));
    }

    /// What the selection covers of line `index`, its layout already shaped, or
    /// none when it covers none of it.
    fn selectionOn(
        self: *const TextView,
        model: *const Model,
        entry: *const LineLayout,
        index: usize,
        x: f32,
        baseline: f32,
    ) ?Sprite {
        const start = self.file.buffer.lineStart(index);
        const band = bandOn(self.file.selected(), start, start + self.file.buffer.lineLength(index)) orelse
            return null;

        const left = @round(caretX(entry.carets.items, band.first));
        var right = @round(caretX(entry.carets.items, band.last));
        if (band.newline) right += @round(newline_stub * model.atlas.scale);
        if (right <= left) return null;

        return .solid(
            .{ x + left, baseline - @round(model.atlas.ascent) },
            .{ right - left, @round(model.atlas.line_height) },
        );
    }

    /// The caret's quad on `index`, whose layout must already be shaped.
    fn caretOn(
        self: *const TextView,
        model: *const Model,
        entry: *const LineLayout,
        index: usize,
        x: f32,
        baseline: f32,
    ) Sprite {
        const offset = self.file.cursor - self.file.buffer.lineStart(index);
        return .solid(.{
            x + @round(caretX(entry.carets.items, offset)),
            baseline - @round(model.atlas.ascent),
        }, .{ @round(caret_width * model.atlas.scale), @round(model.atlas.line_height) });
    }

    /// A click below the last line or past a line's end lands on the nearest
    /// place the caret can go, which is what makes dragging past the end behave.
    fn caretAt(self: *const TextView, model: *const Model, point: [2]f32, extend: bool) Message {
        const where = self.landing(model, point) orelse return .none;
        return .{ .caret = .{ .column = self.which, .at = where.offset, .extend = extend } };
    }

    /// What a double-click takes, which is decided by what it landed on: the
    /// line when it fell past the end of one, what a bracket holds when it fell
    /// beside one, and the word otherwise.
    ///
    /// A click that lands on none of those -- on a space, say -- leaves the
    /// caret the first of the two presses put there rather than reaching for
    /// something to select.
    fn chooseAt(self: *const TextView, model: *const Model, point: [2]f32) Message {
        const where = self.landing(model, point) orelse return .none;
        const buffer = &self.file.buffer;

        if (where.past_end) return self.take(wholeLine(buffer, where.index));
        if (bracketAround(buffer, where.offset)) |inside| return self.take(inside);
        if (wordAround(buffer, where.offset)) |word| return self.take(word);
        return .none;
    }

    fn take(self: *const TextView, span: Span) Message {
        return .{ .selection = .{ .column = self.which, .from = span.from, .to = span.to } };
    }

    /// Acme's look: select the next place the clicked word appears -- or the next
    /// place the current selection's text does, so looking again steps on. The
    /// search wraps, so a word that appears once is found again where it is.
    fn lookAt(self: *const TextView, model: *const Model, point: [2]f32) Message {
        const where = self.landing(model, point) orelse return .none;
        const buffer = &self.file.buffer;

        // Inside the selection: look for that, so a second look steps on. A word
        // otherwise, which is what the first look on fresh text takes.
        const chosen = self.file.selected();
        const inside = !chosen.empty() and where.offset >= chosen.from and where.offset <= chosen.to;
        const target = if (inside) chosen else wordAround(buffer, where.offset) orelse return .none;

        const found = searchFrom(buffer, target, target.to) orelse return .none;
        return .{ .selection = .{
            .column = self.which,
            .from = found.from,
            .to = found.to,
            .follow = true,
            .warp = true,
        } };
    }

    /// Where a point falls: which line, how far into the file, and whether it
    /// landed past the last glyph -- which is what makes a click out to the right
    /// mean the line. The row can clamp to a line not yet shaped, so shape it.
    fn landing(self: *const TextView, model: *const Model, point: [2]f32) ?Landing {
        if (self.file.lines.items.len == 0) return null;

        const at = self.origin(model);
        const row = (point[1] - at[1] + self.file.scroll) / model.atlas.line_height;
        const index = if (row < 0)
            0
        else
            @min(self.file.buffer.lineCount() - 1, @as(usize, @intFromFloat(row)));

        const entry = &self.file.lines.items[index];
        if (model.atlas.stale(entry)) {
            const text = self.file.buffer.lineSlice(index) catch return null;
            model.atlas.shapeLine(text, entry) catch return null;
        }

        const x = point[0] - at[0];
        return .{
            .index = index,
            .offset = self.file.buffer.lineStart(index) + caretOffset(entry.carets.items, x),
            .past_end = x > entry.carets.items[entry.carets.items.len - 1].x,
        };
    }
};

/// Where a point fell, once the line it fell on has been shaped.
const Landing = struct {
    index: usize,
    /// Into the file, not into the line.
    offset: usize,
    /// Right of the last glyph on the line, where there is no character to put
    /// a caret in front of.
    past_end: bool,
};

/// The whole of line `index`, its ending included, so that a line taken this
/// way can be cut out and put back as a line rather than as a run of text. The
/// last line of a file has no ending and stops at the end of the file.
fn wholeLine(buffer: *const Buffer, index: usize) Span {
    const start = buffer.lineStart(index);
    const end = if (index + 1 < buffer.lineCount())
        buffer.lineStart(index + 1)
    else
        buffer.byteLen();
    return .{ .from = start, .to = end };
}

fn opening(byte: u8) ?u8 {
    return switch (byte) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => null,
    };
}

fn closing(byte: u8) ?u8 {
    return switch (byte) {
        ')' => '(',
        ']' => '[',
        '}' => '{',
        else => null,
    };
}

/// What the bracket beside `offset` holds, the bracket itself left out, or none.
/// The one ahead of the caret wins over the one behind. Nesting is counted and
/// nothing else: a bracket in a string counts, the price of not knowing the
/// language.
fn bracketAround(buffer: *const Buffer, offset: usize) ?Span {
    if (offset < buffer.byteLen()) {
        const ahead = buffer.byteAt(offset);
        if (opening(ahead)) |shut| {
            if (matchForward(buffer, offset, ahead, shut)) |found| {
                return .{ .from = offset + 1, .to = found };
            }
        }
        if (closing(ahead)) |open| {
            if (matchBackward(buffer, offset, ahead, open)) |found| {
                return .{ .from = found + 1, .to = offset };
            }
        }
    }

    if (offset > 0) {
        const behind = buffer.byteAt(offset - 1);
        if (opening(behind)) |shut| {
            if (matchForward(buffer, offset - 1, behind, shut)) |found| {
                return .{ .from = offset, .to = found };
            }
        }
        if (closing(behind)) |open| {
            if (matchBackward(buffer, offset - 1, behind, open)) |found| {
                return .{ .from = found + 1, .to = offset - 1 };
            }
        }
    }

    return null;
}

/// Where the bracket at `from` is closed, counting the ones opened on the way.
fn matchForward(buffer: *const Buffer, from: usize, open: u8, shut: u8) ?usize {
    var depth: usize = 1;
    var at = from + 1;
    while (at < buffer.byteLen()) : (at += 1) {
        const byte = buffer.byteAt(at);
        if (byte == open) {
            depth += 1;
        } else if (byte == shut) {
            depth -= 1;
            if (depth == 0) return at;
        }
    }
    return null;
}

/// Where the bracket at `from` was opened, counting the ones closed on the way.
fn matchBackward(buffer: *const Buffer, from: usize, shut: u8, open: u8) ?usize {
    var depth: usize = 1;
    var at = from;
    while (at > 0) {
        at -= 1;
        const byte = buffer.byteAt(at);
        if (byte == shut) {
            depth += 1;
        } else if (byte == open) {
            depth -= 1;
            if (depth == 0) return at;
        }
    }
    return null;
}

/// Letters, digits, underscore, and every byte above ASCII -- taking all the
/// high bytes keeps an accented word whole, without the Unicode tables that
/// telling letters from the rest would need.
fn inWord(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => byte >= 0x80,
    };
}

/// The word `offset` is in, or none when it is not in one.
///
/// The character ahead of the caret decides, and the one behind it when there
/// is no word ahead: a double-click at either edge of a word means that word.
fn wordAround(buffer: *const Buffer, offset: usize) ?Span {
    const end = buffer.byteLen();

    var from = offset;
    if (from < end and inWord(buffer.byteAt(from))) {
        // In a word already.
    } else if (from > 0 and inWord(buffer.byteAt(from - 1))) {
        from -= 1;
    } else {
        return null;
    }

    var to = from;
    while (to < end and inWord(buffer.byteAt(to))) to += 1;
    while (from > 0 and inWord(buffer.byteAt(from - 1))) from -= 1;
    return .{ .from = from, .to = to };
}

/// The next run of bytes equal to `target`'s, at or after `from`, wrapping once
/// through the start of the file. The target is offsets, not bytes, so nothing
/// has to be copied out to search -- a slice would be gone by the next call.
fn searchFrom(buffer: *const Buffer, target: Span, from: usize) ?Span {
    const len = target.to - target.from;
    if (len == 0) return null;

    const total = buffer.byteLen();
    if (len > total) return null;

    // Starts walked from `from` and wrapped to zero, so the match after the
    // selection is found first and the one before it last.
    const last = total - len;
    var at: usize = if (from <= last) from else 0;
    var remaining = last + 1;
    while (remaining > 0) : (remaining -= 1) {
        if (matchesAt(buffer, target, at)) return .{ .from = at, .to = at + len };
        at = if (at == last) 0 else at + 1;
    }
    return null;
}

fn matchesAt(buffer: *const Buffer, target: Span, at: usize) bool {
    var i: usize = 0;
    while (i < target.to - target.from) : (i += 1) {
        if (buffer.byteAt(at + i) != buffer.byteAt(target.from + i)) return false;
    }
    return true;
}

/// What a selection covers of one line, as offsets within it.
const Band = struct {
    first: usize,
    last: usize,
    /// Whether the line's ending is inside the selection, which is what says
    /// the selection carries on past the last glyph.
    newline: bool,
};

/// What `span` covers of the line running `[start, end)`, where `end` is the
/// last byte before the newline rather than the newline itself.
///
/// None when the line has none of it. A selection that reaches `end` and
/// carries on has taken the ending with it, which the line after this one
/// knows nothing about -- so it is answered here.
fn bandOn(span: Span, start: usize, end: usize) ?Band {
    if (span.empty()) return null;
    if (span.to <= start or span.from > end) return null;

    return .{
        .first = @max(span.from, start) - start,
        .last = @min(span.to, end) - start,
        .newline = span.to > end,
    };
}

/// A function of the index rather than a running total: float addition does not
/// associate, so adding `line_height` up from the first visible line and up from
/// line zero can fall either side of a `@round` -- a line jumping a pixel by
/// where it was scrolled from.
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
    // Ceil, not `@floor(..) + 1`, which is one too many when the division is even.
    const above = scroll - top;
    const first = clampIndex(@floor(above / line_height), count);
    const last = clampIndex(@ceil((above + height) / line_height), count);
    return .{ .first = first, .last = @max(first, last) };
}

const Thumb = struct { y: f32, height: f32 };

/// The thumb is the window's share of the track, which stands for the file. Past
/// the last line it carries below the track and is clipped, which is truer than
/// counting empty space as something to scroll through.
fn thumb(scroll: f32, content: f32, height: f32, minimum: f32) Thumb {
    if (content <= 0) return .{ .y = 0, .height = height };
    const share = height / content;
    return .{
        .y = @round(scroll * share),
        .height = @min(height, @max(minimum, @round(height * share))),
    };
}

test "the thumb is the window's share of the file" {
    const t = thumb(0, 200, 100, 10);
    try std.testing.expectEqual(@as(f32, 0), t.y);
    try std.testing.expectEqual(@as(f32, 50), t.height);
}

test "the thumb reaches the bottom when the last line does" {
    const t = thumb(100, 200, 100, 10);
    try std.testing.expectEqual(@as(f32, 50), t.y);
    try std.testing.expectEqual(@as(f32, 50), t.height);
}

test "scrolling past the last line carries the thumb below the track" {
    const t = thumb(160, 200, 100, 10);
    try std.testing.expectEqual(@as(f32, 80), t.y);
    try std.testing.expect(t.y + t.height > 100);
}

test "a file shorter than the window fills the track" {
    try std.testing.expectEqual(@as(f32, 100), thumb(0, 40, 100, 10).height);
}

test "a long file stops shrinking the thumb at the minimum" {
    try std.testing.expectEqual(@as(f32, 24), thumb(0, 1_000_000, 100, 24).height);
}

/// Where the scroll has to move to centre line `index`, or the scroll it was
/// given when the line is already on screen. The middle, not an edge, so what is
/// around the caret shows either side of it.
fn scrollToCentre(scroll: f32, index: usize, top: f32, height: f32, line_height: f32) f32 {
    const y = lineTop(index, top, scroll, line_height);
    if (y >= 0 and y + line_height <= height) return scroll;
    return @round(scroll + y - (height - line_height) / 2);
}

/// Into `[0, count]` before it becomes an integer: `@intFromFloat` is undefined
/// outside its target's range, and nothing bounds this but the window size.
fn clampIndex(value: f32, count: usize) usize {
    // Negated so a NaN, which compares false either way, lands here rather than
    // on a conversion with no answer for it.
    if (!(value > 0)) return 0;
    const limit: f32 = @floatFromInt(count);
    if (value >= limit) return count;
    return @intFromFloat(value);
}

test "a viewport taller than the file shows all of it" {
    const range = visibleLines(10, 0, 1000, 15, 4);
    try std.testing.expectEqual(@as(usize, 0), range.first);
    try std.testing.expectEqual(@as(usize, 4), range.last);
}

test "a viewport shorter than the file stops short of its end" {
    try std.testing.expectEqual(@as(usize, 6), visibleLines(10, 0, 100, 15, 10).last);
}

test "a line beginning exactly at the bottom edge is not drawn" {
    // The edge itself is out; `@floor(..) + 1` would wrongly answer 4 here.
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
    // clamps that back to the top of the file.
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

/// How far along a line an offset sits. Cluster boundaries are not character
/// boundaries -- `ffi` covers three bytes with none inside -- so an offset landing
/// inside a cluster divides its width across its bytes, an approximation.
fn caretX(carets: []const Caret, offset: usize) f32 {
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

/// Which offset a click at `target` means -- the nearest boundary, so clicking
/// the right half of a character puts the caret after it.
fn caretOffset(carets: []const Caret, target: f32) usize {
    std.debug.assert(carets.len > 0);

    // Sorted by x: the pen only moves right, with no bidi pass.
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
    // Tests follow the imports: this file pulls in the file's, so a test
    // build reaches them without `main` having to know they exist.
    _ = @import("../open_file.zig");
    _ = @import("../painter.zig");
}

// A file of three lines: "one\ntwo\nthree", so line 1 is `[4, 7)` and byte 7 is
// the newline that ends it.
const line_start = 4;
const line_end = 7;

test "a line outside the selection has no band" {
    try std.testing.expectEqual(@as(?Band, null), bandOn(.{ .from = 0, .to = 3 }, line_start, line_end));
    try std.testing.expectEqual(@as(?Band, null), bandOn(.{ .from = 8, .to = 13 }, line_start, line_end));

    // A caret is a selection of nothing.
    try std.testing.expectEqual(@as(?Band, null), bandOn(.{ .from = 5, .to = 5 }, line_start, line_end));
}

test "a selection inside one line is that much of it" {
    const band = bandOn(.{ .from = 5, .to = 6 }, line_start, line_end).?;
    try std.testing.expectEqual(@as(usize, 1), band.first);
    try std.testing.expectEqual(@as(usize, 2), band.last);
    try std.testing.expect(!band.newline);
}

test "a selection running past the line takes its ending with it" {
    const band = bandOn(.{ .from = 5, .to = 10 }, line_start, line_end).?;
    try std.testing.expectEqual(@as(usize, 1), band.first);
    try std.testing.expectEqual(@as(usize, 3), band.last);
    try std.testing.expect(band.newline);
}

test "a selection reaching exactly the end of the line leaves it out" {
    const band = bandOn(.{ .from = 4, .to = 7 }, line_start, line_end).?;
    try std.testing.expectEqual(@as(usize, 0), band.first);
    try std.testing.expectEqual(@as(usize, 3), band.last);
    try std.testing.expect(!band.newline);
}

test "a selection of the ending alone is the stub and nothing else" {
    const band = bandOn(.{ .from = 7, .to = 8 }, line_start, line_end).?;
    try std.testing.expectEqual(@as(usize, 3), band.first);
    try std.testing.expectEqual(@as(usize, 3), band.last);
    try std.testing.expect(band.newline);
}

test "a line wholly inside a longer selection is covered end to end" {
    const band = bandOn(.{ .from = 0, .to = 13 }, line_start, line_end).?;
    try std.testing.expectEqual(@as(usize, 0), band.first);
    try std.testing.expectEqual(@as(usize, 3), band.last);
    try std.testing.expect(band.newline);
}

/// The double-click rules read bytes and lines only, so no window is needed.
fn textOf(comptime text: []const u8) Buffer {
    return Buffer.init(std.testing.allocator, text) catch unreachable;
}

test "a double-click in a word takes the word" {
    var buffer = textOf("one two three");
    defer buffer.deinit();

    // From inside it, from its first edge, and from its last.
    try std.testing.expectEqual(Span{ .from = 4, .to = 7 }, wordAround(&buffer, 5).?);
    try std.testing.expectEqual(Span{ .from = 4, .to = 7 }, wordAround(&buffer, 4).?);
    try std.testing.expectEqual(Span{ .from = 4, .to = 7 }, wordAround(&buffer, 7).?);
}

test "a word runs through digits and underscores and stops at punctuation" {
    var buffer = textOf("a.some_name2.b");
    defer buffer.deinit();

    try std.testing.expectEqual(Span{ .from = 2, .to = 12 }, wordAround(&buffer, 6).?);
}

test "a look finds the next occurrence of the target and wraps" {
    var buffer = textOf("one two one two");
    defer buffer.deinit();

    // The first `one` is bytes 0..3. Looking from its end finds the second.
    try std.testing.expectEqual(Span{ .from = 8, .to = 11 }, searchFrom(&buffer, .{ .from = 0, .to = 3 }, 3).?);

    // Looking on from the second wraps round to the first.
    try std.testing.expectEqual(Span{ .from = 0, .to = 3 }, searchFrom(&buffer, .{ .from = 8, .to = 11 }, 11).?);
}

test "a look for a word that appears once lands back on it" {
    var buffer = textOf("alpha beta gamma");
    defer buffer.deinit();

    // `beta` is bytes 6..10, and there is nowhere else for it to go.
    try std.testing.expectEqual(Span{ .from = 6, .to = 10 }, searchFrom(&buffer, .{ .from = 6, .to = 10 }, 10).?);
}

test "a look matches the exact bytes, not whole words" {
    var buffer = textOf("in int in");
    defer buffer.deinit();

    // Looking for `in` from the end of the first lands on the `in` inside
    // `int`: the search is over bytes, and knows nothing of word boundaries.
    try std.testing.expectEqual(Span{ .from = 3, .to = 5 }, searchFrom(&buffer, .{ .from = 0, .to = 2 }, 2).?);
}

test "a double-click on nothing takes nothing" {
    var buffer = textOf("one   two");
    defer buffer.deinit();

    // Between the spaces, with no word on either side of the caret.
    try std.testing.expectEqual(@as(?Span, null), wordAround(&buffer, 5));
}

test "a double-click beside a bracket takes what is inside it" {
    var buffer = textOf("call(a, b) end");
    defer buffer.deinit();

    // Either side of the opener, then either side of the closer.
    try std.testing.expectEqual(Span{ .from = 5, .to = 9 }, bracketAround(&buffer, 4).?);
    try std.testing.expectEqual(Span{ .from = 5, .to = 9 }, bracketAround(&buffer, 5).?);
    try std.testing.expectEqual(Span{ .from = 5, .to = 9 }, bracketAround(&buffer, 9).?);
    try std.testing.expectEqual(Span{ .from = 5, .to = 9 }, bracketAround(&buffer, 10).?);
}

test "the bracket taken is the innermost one the click is beside" {
    var buffer = textOf("f(g(x), y)");
    defer buffer.deinit();

    // Beside the inner opener: the inner pair, not the outer one it is in.
    try std.testing.expectEqual(Span{ .from = 4, .to = 5 }, bracketAround(&buffer, 4).?);
    // Beside the outer opener: the outer pair, whose closer is past the inner.
    try std.testing.expectEqual(Span{ .from = 2, .to = 9 }, bracketAround(&buffer, 2).?);
}

test "a bracket that nothing closes takes nothing" {
    var buffer = textOf("f(g, h");
    defer buffer.deinit();

    try std.testing.expectEqual(@as(?Span, null), bracketAround(&buffer, 2));
}

test "the three kinds of bracket are matched only against their own" {
    var buffer = textOf("a[b{c}d]e");
    defer buffer.deinit();

    try std.testing.expectEqual(Span{ .from = 2, .to = 7 }, bracketAround(&buffer, 2).?);
    try std.testing.expectEqual(Span{ .from = 4, .to = 5 }, bracketAround(&buffer, 4).?);
}

test "a whole line carries its ending, and the last line has none to carry" {
    var buffer = textOf("one\ntwo\nthree");
    defer buffer.deinit();

    // Through to the start of the next line, so cutting it takes the break too.
    try std.testing.expectEqual(Span{ .from = 0, .to = 4 }, wholeLine(&buffer, 0));
    try std.testing.expectEqual(Span{ .from = 4, .to = 8 }, wholeLine(&buffer, 1));

    // The last line stops at the end of the file.
    try std.testing.expectEqual(Span{ .from = 8, .to = 13 }, wholeLine(&buffer, 2));
}
