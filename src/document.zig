//! The document: the text itself, where its lines begin, and what each line
//! shaped to.
//!
//! Everything here is derived from the bytes and from nothing a view has. What
//! a view keeps of its own is where its caret is and how far down it is
//! looking. See components/text_view.zig.

const std = @import("std");

const LineLayout = @import("./glyph_atlas.zig").LineLayout;

/// What an edit did to the line index, so anything else keyed by line can be
/// spliced rather than rebuilt. Both counts are of lines after `line`.
pub const Edit = struct {
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
pub const Buffer = struct {
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

    pub fn init(gpa: std.mem.Allocator, text: []const u8) !Buffer {
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

    pub fn deinit(self: *Buffer) void {
        self.scratch.deinit(self.gpa);
        self.starts.deinit(self.gpa);
        self.gpa.free(self.bytes);
    }

    pub fn byteLen(self: *const Buffer) usize {
        return self.bytes.len - (self.gap_end - self.gap_start);
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.starts.items.len;
    }

    /// Inserts `text` so that its first byte lands at `at`.
    pub fn insert(self: *Buffer, at: usize, text: []const u8) !Edit {
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
    pub fn delete(self: *Buffer, at: usize, count: usize) Edit {
        std.debug.assert(at + count <= self.byteLen());
        const line = self.lineAt(at);
        if (count == 0) return .{ .line = line, .removed = 0, .added = 0 };

        self.moveGap(at);
        self.gap_end += count;

        return .{ .line = line, .removed = self.reindexDelete(line, at, count), .added = 0 };
    }

    /// Line `index` without its newline. The result borrows from the buffer and
    /// is good until the next edit.
    pub fn lineSlice(self: *Buffer, index: usize) ![]const u8 {
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
    pub fn lineStart(self: *const Buffer, index: usize) usize {
        std.debug.assert(index < self.lineCount());
        return self.starts.items[index];
    }

    /// Without reading it. A cached line is never fetched, so this is what
    /// checks the cache still lines up with the document.
    pub fn lineLength(self: *const Buffer, index: usize) usize {
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
    pub fn stepBack(self: *const Buffer, offset: usize) usize {
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
    pub fn lineAt(self: *const Buffer, offset: usize) usize {
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

/// The text and everything derived from it.
///
/// The layout cache is here rather than in the view because shaping depends on
/// a line's bytes and on the atlas scale, and on nothing a view has. Keeping it
/// beside the text is also what lets `insert` and `delete` splice it themselves,
/// rather than leaving a caller to remember to.
pub const Document = struct {
    gpa: std.mem.Allocator,
    buffer: Buffer,

    /// One entry per line, in the document's order. Empty until the first frame,
    /// which is where it learns how many lines there are.
    lines: std.ArrayList(LineLayout) = .empty,

    pub fn init(gpa: std.mem.Allocator, text: []const u8) !Document {
        return .{ .gpa = gpa, .buffer = try Buffer.init(gpa, text) };
    }

    pub fn deinit(self: *Document) void {
        for (self.lines.items) |*entry| {
            entry.sprites.deinit(self.gpa);
            entry.carets.deinit(self.gpa);
        }
        self.lines.deinit(self.gpa);
        self.buffer.deinit();
    }

    pub fn insert(self: *Document, at: usize, text: []const u8) !Edit {
        const edit = try self.buffer.insert(at, text);
        try self.splice(edit);
        return edit;
    }

    pub fn delete(self: *Document, at: usize, count: usize) !Edit {
        const edit = self.buffer.delete(at, count);
        try self.splice(edit);
        return edit;
    }

    /// Drops every shaped line, for after the atlas is rebuilt at a different
    /// scale. Nothing cached survives that: the positions are in pixels of the
    /// old size, and scaling them is not the same answer, because hinting and
    /// rounding do not distribute over a scale.
    ///
    /// The entries stay, so the cache is still one per line and in step with the
    /// document.
    pub fn invalidate(self: *Document) void {
        for (self.lines.items) |*entry| entry.shaped = false;
    }

    fn splice(self: *Document, edit: Edit) !void {
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
/// Apart from `Document` so it can be tested without one to splice.
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
