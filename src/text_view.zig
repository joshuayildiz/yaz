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
const GlyphAtlas = glyph_atlas.GlyphAtlas;
const LineLayout = glyph_atlas.LineLayout;
const Sprite = glyph_atlas.Sprite;

pub const TextView = struct {
    gpa: std.mem.Allocator,
    document: Buffer,

    /// One entry per line of the document, in the document's order. Shaping is
    /// the expensive half of laying a line out and depends only on the line's
    /// bytes, so it is done once and kept.
    lines: std.ArrayList(LineLayout) = .empty,

    /// Where the next character lands, as a byte offset into the document.
    /// Nothing draws it yet; the caret and clicking to move it are step 13.
    cursor: usize,

    /// The frame's glyphs, placed on screen. Cleared rather than freed between
    /// frames: it settles at the size of a screenful and stops allocating,
    /// which is what keeps a redraw free of the allocator.
    sprites: std.ArrayList(Sprite) = .empty,

    pub fn init(gpa: std.mem.Allocator, text: []const u8) !TextView {
        return .{
            .gpa = gpa,
            .document = try Buffer.init(gpa, text),
            .cursor = text.len,
        };
    }

    pub fn deinit(self: *TextView) void {
        self.sprites.deinit(self.gpa);
        for (self.lines.items) |*entry| entry.sprites.deinit(self.gpa);
        self.lines.deinit(self.gpa);
        self.document.deinit();
    }

    pub fn insert(self: *TextView, text: []const u8) !void {
        const edit = try self.document.insert(self.cursor, text);
        try self.splice(edit);
        self.cursor += text.len;
    }

    /// Deletes the character before the caret, answering whether there was one.
    pub fn backspace(self: *TextView) !bool {
        const from = self.document.stepBack(self.cursor);
        if (from == self.cursor) return false;

        const edit = self.document.delete(from, self.cursor - from);
        try self.splice(edit);
        self.cursor = from;
        return true;
    }

    /// Places every line's glyphs on screen, shaping the ones whose text has
    /// changed since they were last seen. `top` is the top of the first line,
    /// not its baseline.
    ///
    /// A redraw that changed nothing shapes nothing and does not so much as
    /// read the document; a keystroke shapes the one line it landed in. What
    /// remains per frame is placing the cached glyphs, which has to happen
    /// anyway to fill the buffer the GPU reads.
    pub fn layout(self: *TextView, atlas: *GlyphAtlas, x: f32, top: f32) ![]const Sprite {
        // Cached glyphs are placed by adding whole pixels. A fractional origin
        // would change which subpixel variant each one points at, and the cache
        // would be answering the wrong question.
        std.debug.assert(x == @round(x));

        self.sprites.clearRetainingCapacity();
        const count = self.document.lineCount();
        if (self.lines.items.len == 0) try self.lines.appendNTimes(self.gpa, .{}, count);
        // Anything else means an edit did not reach the cache and the entries
        // no longer line up with the lines they describe.
        std.debug.assert(self.lines.items.len == count);

        var baseline = top + atlas.ascent;
        for (self.lines.items, 0..) |*entry, index| {
            if (!entry.shaped) try atlas.shapeLine(try self.document.lineSlice(index), entry);
            std.debug.assert(entry.bytes == self.document.lineLength(index));

            const origin: [2]f32 = .{ x, @round(baseline) };
            try self.sprites.ensureUnusedCapacity(self.gpa, entry.sprites.items.len);
            for (entry.sprites.items) |sprite| {
                self.sprites.appendAssumeCapacity(.{
                    .dest = .{ sprite.dest[0] + origin[0], sprite.dest[1] + origin[1] },
                    .source = sprite.source,
                    .size = sprite.size,
                });
            }

            baseline += atlas.line_height;
        }

        return self.sprites.items;
    }

    fn splice(self: *TextView, edit: Edit) !void {
        // Nothing has been laid out yet, so there is nothing to keep in step.
        if (self.lines.items.len == 0) return;
        try spliceLines(self.gpa, &self.lines, edit.line, edit.removed, edit.added);
    }
};

/// Brings the cache back into step with the document after an edit, told what
/// that edit did to the line index: which line it landed in, how many lines
/// after it stopped existing, and how many came into being.
///
/// Every other entry survives untouched. A line that moved down the screen is
/// the same shaped line at a different baseline, which is the whole reason its
/// glyphs are kept in coordinates of their own.
///
/// Apart from `TextView` so that it can be tested without a document to splice.
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

    for (cache.items[first..][0..removed]) |*entry| entry.sprites.deinit(gpa);
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

/// What an edit did to the line index, so that anything else keyed by line can
/// be spliced the same way rather than thrown away and rebuilt. Both counts are
/// of lines after `line`.
const Edit = struct {
    /// The line the edit landed in. Its bytes changed; no other line's did.
    line: usize,
    /// Lines that stopped existing, their newlines having been deleted.
    removed: usize,
    /// Lines that came into being, from newlines in the inserted text.
    added: usize,
};

/// How much room a reallocation leaves ahead of the text. Typing arrives one
/// character at a time, and a buffer sized to fit exactly would reallocate on
/// every keystroke.
const min_gap = 4096;

/// The document: one contiguous allocation with a hole in it, kept wherever the
/// last edit happened.
///
/// Inserting or deleting at the hole is a write and a bounds change -- nothing
/// moves, nothing is allocated. Editing anywhere else moves the hole there
/// first, which costs one memmove of the bytes in between. That is the bet the
/// structure makes: editing is local, so the distance is usually a few
/// characters, and the occasional jump across the whole file is one pass at
/// memory bandwidth rather than a data structure to maintain.
const Buffer = struct {
    gpa: std.mem.Allocator,

    /// Text and hole together. `bytes[0..gap_start]` and `bytes[gap_end..]` are
    /// the document; what lies between them is not part of it.
    bytes: []u8,
    gap_start: usize,
    gap_end: usize,

    /// Where each line begins, counting the gap as absent. Lines cannot be
    /// found by arithmetic once they are variable-length strings set in a
    /// proportional font, so they are indexed, and the index is patched on each
    /// edit rather than rebuilt. A line begins at 0 and after every newline, so
    /// text ending in one ends with an empty line.
    starts: std.ArrayList(usize),

    /// A line containing the gap is not contiguous, so returning it as a slice
    /// means copying it out first. Only one line can contain the gap, which is
    /// what lets a single scratch buffer serve all of them.
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

    /// How long line `index` is, without reading it. A line whose layout is
    /// cached is never fetched, so this is what checks the cache still lines up
    /// with the document.
    fn lineLength(self: *const Buffer, index: usize) usize {
        std.debug.assert(index < self.lineCount());
        const from = self.starts.items[index];
        const to = if (index + 1 < self.lineCount())
            self.starts.items[index + 1] - 1
        else
            self.byteLen();
        return to - from;
    }

    /// The offset one character before `offset`, or `offset` itself at the
    /// start of the document.
    ///
    /// A whole UTF-8 sequence, because half a character is not something the
    /// document can hold. Not yet a whole grapheme cluster: `e` followed by a
    /// combining acute is two of these, and backspacing over it takes two
    /// presses. Getting that right needs the Unicode tables `zg` carries, and
    /// it is not worth the dependency until cursor movement exists to be wrong
    /// about.
    fn stepBack(self: *const Buffer, offset: usize) usize {
        var at = offset;
        while (at > 0) {
            at -= 1;
            // Continuation bytes are 10xxxxxx; anything else begins a
            // character.
            if (self.byteAt(at) & 0xc0 != 0x80) break;
        }
        return at;
    }

    fn byteAt(self: *const Buffer, offset: usize) u8 {
        std.debug.assert(offset < self.byteLen());
        const gap = self.gap_end - self.gap_start;
        return if (offset < self.gap_start) self.bytes[offset] else self.bytes[offset + gap];
    }

    /// The line `offset` falls on: the last one starting at or before it.
    /// Binary search, because this is what an edit and a mouse click both need
    /// and neither knows the answer already.
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

    /// Puts the hole at `to` by moving the bytes in between across it. The one
    /// operation here that is not constant time, and what an edit away from the
    /// last one costs.
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
    /// newline inside it begins a line of its own. `added` is how many, counted
    /// by the caller so the room for them could be reserved before anything
    /// was written.
    fn reindexInsert(self: *Buffer, line: usize, at: usize, text: []const u8, added: usize) void {
        const starts = &self.starts;
        // Line starts at exactly `at` do not move: text inserted there becomes
        // the beginning of that line rather than the end of the one before.
        const after = line + 1;

        // One shift for all the new lines rather than one shift each, which
        // would make pasting a large block quadratic in its line count.
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

    /// A line start in `(at, at + count]` is one whose newline was inside the
    /// deleted range, so it stops being a line; what is left after the range
    /// shifts back by its length.
    /// Answers how many lines stopped existing.
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

