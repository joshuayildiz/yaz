const std = @import("std");

const Renderer = @import("./renderer.zig").Renderer;
const sdl = @import("./sdl.zig");
const c = sdl.c;

pub fn main(init: std.process.Init) !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.err("SDL_Init: {s}", .{sdl.lastError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("yaz", 1024, 768, c.SDL_WINDOW_RESIZABLE) orelse {
        std.log.err("SDL_CreateWindow: {s}", .{sdl.lastError()});
        return error.SdlCreateWindow;
    };
    defer c.SDL_DestroyWindow(window);

    std.log.info("video driver: {s}", .{std.mem.span(c.SDL_GetCurrentVideoDriver())});

    // Text arrives as finished characters rather than keys. The platform's
    // input method gets the keystrokes first, so a dead key, a compose
    // sequence or a CJK conversion has already become the character it means
    // by the time it reaches us.
    if (!c.SDL_StartTextInput(window)) {
        std.log.err("SDL_StartTextInput: {s}", .{sdl.lastError()});
        return error.SdlStartTextInput;
    }
    defer _ = c.SDL_StopTextInput(window);

    var app: App = .{
        .renderer = try Renderer.init(init.gpa, window),
        .document = try Buffer.init(init.gpa, sample_text),
        .cursor = sample_text.len,
    };
    defer app.renderer.deinit();
    defer app.document.deinit();

    if (!c.SDL_AddEventWatch(redrawWhileResizing, &app)) {
        std.log.err("SDL_AddEventWatch: {s}", .{sdl.lastError()});
        return error.SdlAddEventWatch;
    }
    defer c.SDL_RemoveEventWatch(redrawWhileResizing, &app);

    // Blocking wait, not a poll loop: idle costs nothing. Waking up is not a
    // reason to draw, though; only a change to what is on screen is.
    var dirty = true;
    var running = true;
    var event: c.SDL_Event = undefined;
    while (running) {
        if (dirty) {
            try app.redraw();
            dirty = false;
        }

        if (!c.SDL_WaitEvent(&event)) {
            std.log.err("SDL_WaitEvent: {s}", .{sdl.lastError()});
            return error.SdlWaitEvent;
        }

        // Everything already queued belongs to the frame this wakeup produces.
        // Folding a burst into one redraw is what stops a keystroke queueing up
        // behind presents of unchanged content: presenting blocks on the
        // swapchain, so each redundant one costs real latency, not just work.
        while (true) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => dirty = true,
                c.SDL_EVENT_TEXT_INPUT => {
                    try app.insert(std.mem.span(event.text.text));
                    dirty = true;
                },
                // Return and backspace are not text and do not arrive as any.
                c.SDL_EVENT_KEY_DOWN => switch (event.key.key) {
                    c.SDLK_RETURN => {
                        try app.insert("\n");
                        dirty = true;
                    },
                    c.SDLK_BACKSPACE => {
                        if (app.backspace()) dirty = true;
                    },
                    else => {},
                },
                // Exposure belongs to the watcher, which has already drawn by
                // the time the event arrives here; marking it would draw twice.
                else => {},
            }
            if (!c.SDL_PollEvent(&event)) break;
        }
    }
}

/// The document, where typing goes into it, and the thing that draws it --
/// together because the event watch needs them from behind one `void *`.
const App = struct {
    renderer: Renderer,
    document: Buffer,

    /// Where the next character lands, as a byte offset into the document.
    /// Nothing draws it yet; the caret and clicking to move it are step 13.
    cursor: usize,

    fn redraw(self: *App) !void {
        try self.renderer.present(try self.document.lines());
    }

    fn insert(self: *App, text: []const u8) !void {
        try self.document.insert(self.cursor, text);
        self.cursor += text.len;
    }

    /// Deletes the character before the cursor, answering whether there was
    /// one.
    fn backspace(self: *App) bool {
        const from = self.document.stepBack(self.cursor);
        if (from == self.cursor) return false;

        self.document.delete(from, self.cursor - from);
        self.cursor = from;
        return true;
    }
};

/// Windows and macOS run a modal loop of their own while a window is being
/// dragged or resized, and it does not hand control back until the drag ends.
/// `SDL_WaitEvent` is stuck inside it, so nothing redraws, and the area the
/// window has just grown into keeps whatever the new swapchain came with.
///
/// A watch callback is the way out: SDL runs it as events are pushed, which
/// happens from inside that modal loop.
fn redrawWhileResizing(userdata: ?*anyopaque, event: [*c]c.SDL_Event) callconv(.c) bool {
    if (event.*.type == c.SDL_EVENT_WINDOW_EXPOSED) {
        const app: *App = @ptrCast(@alignCast(userdata.?));
        // Swallowed rather than reported: the main loop draws again the moment
        // it gets control back, and surfaces the failure there.
        app.redraw() catch {};
    }
    // Watch callbacks cannot filter; the return value is ignored.
    return true;
}

/// Enough text to show that advances differ per character, that the pen lands
/// off the pixel grid as a result, and that shaping produces glyphs no character
/// maps to. Replaced by a file to open once there is one.
const sample_text =
    "The quick brown fox jumps over the lazy dog.\n" ++
    "Waltz, bad nymph, for quick jigs vex. 0123456789\n" ++
    // fi, ffi and fl are each one glyph here, and no character maps to any of
    // them: they exist only because shaping substituted them in.
    "office difficult flag fluffy affix\n" ++
    // The second of these is an e followed by a combining acute, which shaping
    // composes into the same single glyph as the first.
    "caf\u{e9} and cafe\u{301} \u{2014} composed and precomposed\n" ++
    // Neither script is in DejaVu Sans, so these come back as .notdef.
    "\u{6f22}\u{5b57} \u{e17}\u{e35} \u{2014} not in this font\n" ++
    "iiiii mmmmm WWWWW ..... proportional, not monospace";

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

    /// Filled by `lines`, kept between calls so that drawing a frame does not
    /// allocate.
    views: std.ArrayList([]const u8) = .empty,

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
        self.views.deinit(self.gpa);
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
    fn insert(self: *Buffer, at: usize, text: []const u8) !void {
        std.debug.assert(at <= self.byteLen());
        if (text.len == 0) return;

        // Both allocations happen before a byte is written, so failing here
        // leaves the document and its index exactly as they were.
        const added = std.mem.count(u8, text, "\n");
        try self.starts.ensureUnusedCapacity(self.gpa, added);
        if (self.gap_end - self.gap_start < text.len) try self.grow(text.len);

        self.moveGap(at);
        @memcpy(self.bytes[self.gap_start..][0..text.len], text);
        self.gap_start += text.len;

        self.reindexInsert(at, text, added);
    }

    /// Deletes the `count` bytes starting at `at`. Cannot fail: the text stays
    /// where it is and the hole grows over it.
    fn delete(self: *Buffer, at: usize, count: usize) void {
        std.debug.assert(at + count <= self.byteLen());
        if (count == 0) return;

        self.moveGap(at);
        self.gap_end += count;

        self.reindexDelete(at, count);
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

    /// Every line in order, for a caller that draws them all.
    ///
    /// Rebuilt on each call rather than cached. Step 12's per-line layout cache
    /// is where not redoing this belongs, and it needs an edit to invalidate
    /// against before it can exist.
    fn lines(self: *Buffer) ![]const []const u8 {
        self.views.clearRetainingCapacity();
        try self.views.ensureTotalCapacity(self.gpa, self.lineCount());
        for (0..self.lineCount()) |index| {
            self.views.appendAssumeCapacity(try self.lineSlice(index));
        }
        return self.views.items;
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
    fn reindexInsert(self: *Buffer, at: usize, text: []const u8, added: usize) void {
        const starts = &self.starts;
        // Line starts at exactly `at` do not move: text inserted there becomes
        // the beginning of that line rather than the end of the one before.
        const after = self.lineAt(at) + 1;

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
    fn reindexDelete(self: *Buffer, at: usize, count: usize) void {
        const starts = &self.starts;
        const first = self.lineAt(at) + 1;

        var last = first;
        while (last < starts.items.len and starts.items[last] <= at + count) last += 1;

        std.mem.copyForwards(usize, starts.items[first..], starts.items[last..]);
        starts.items.len -= last - first;

        for (starts.items[first..]) |*start| start.* -= count;
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
    try buffer.insert(5, ",");
    try std.testing.expectEqualStrings("hello, world", try buffer.lineSlice(0));

    try buffer.insert(0, ">> ");
    try buffer.insert(buffer.byteLen(), "!");
    try std.testing.expectEqualStrings(">> hello, world!", try buffer.lineSlice(0));
}

test "the gap moving back and forth does not disturb the text" {
    var buffer = try Buffer.init(std.testing.allocator, "abcdefghij");
    defer buffer.deinit();

    // Alternating ends, so every insert drags the gap across most of the text.
    try buffer.insert(0, "1");
    try buffer.insert(buffer.byteLen(), "2");
    try buffer.insert(1, "3");
    try buffer.insert(buffer.byteLen() - 1, "4");

    try std.testing.expectEqualStrings("13abcdefghij42", try buffer.lineSlice(0));
}

test "inserting a newline splits a line and shifts the ones after it" {
    var buffer = try Buffer.init(std.testing.allocator, "one\ntwo");
    defer buffer.deinit();

    try buffer.insert(1, "\n");
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 5 }, buffer.starts.items);
    try std.testing.expectEqualStrings("o", try buffer.lineSlice(0));
    try std.testing.expectEqualStrings("ne", try buffer.lineSlice(1));
    try std.testing.expectEqualStrings("two", try buffer.lineSlice(2));
}

test "inserting at a line start belongs to that line, not the one before" {
    var buffer = try Buffer.init(std.testing.allocator, "one\ntwo");
    defer buffer.deinit();

    try buffer.insert(4, "X");
    try std.testing.expectEqualSlices(usize, &.{ 0, 4 }, buffer.starts.items);
    try std.testing.expectEqualStrings("one", try buffer.lineSlice(0));
    try std.testing.expectEqualStrings("Xtwo", try buffer.lineSlice(1));
}

test "pasting several lines indexes all of them at once" {
    var buffer = try Buffer.init(std.testing.allocator, "start\nend");
    defer buffer.deinit();

    try buffer.insert(6, "a\nb\nc\n");
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

    buffer.delete(4, 2);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4, 6 }, buffer.starts.items);
    try std.testing.expectEqualStrings("o", try buffer.lineSlice(1));
    try std.testing.expectEqualStrings("three", try buffer.lineSlice(2));
}

test "deleting a newline joins the lines it separated" {
    var buffer = try Buffer.init(std.testing.allocator, "one\ntwo\nthree");
    defer buffer.deinit();

    buffer.delete(3, 1);
    try std.testing.expectEqual(2, buffer.lineCount());
    try std.testing.expectEqualSlices(usize, &.{ 0, 7 }, buffer.starts.items);
    try std.testing.expectEqualStrings("onetwo", try buffer.lineSlice(0));
    try std.testing.expectEqualStrings("three", try buffer.lineSlice(1));
}

test "deleting across several lines removes every start inside the range" {
    var buffer = try Buffer.init(std.testing.allocator, "one\ntwo\nthree\nfour");
    defer buffer.deinit();

    // From the middle of line 0 to the middle of line 3.
    buffer.delete(2, 14);
    try std.testing.expectEqual(1, buffer.lineCount());
    try std.testing.expectEqualStrings("onur", try buffer.lineSlice(0));
}

test "growing past the initial gap keeps both halves" {
    var buffer = try Buffer.init(std.testing.allocator, "head|tail");
    defer buffer.deinit();

    // Put the hole in the middle first. A new buffer keeps it at the end,
    // where reallocating has nothing behind it to carry across.
    try buffer.insert(4, "!");

    // Longer than the hole in one go, so this reallocates rather than filling
    // what it was given.
    const filler = "x" ** (min_gap + 100);
    try buffer.insert(2, filler);

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
    try buffer.insert(head.len, filler);

    try buffer.insert(0, "<");
    try buffer.insert(buffer.byteLen(), ">");

    const line = try buffer.lineSlice(0);
    try std.testing.expectEqual(head.len + filler.len + 2, line.len);
    try std.testing.expectEqualStrings("<head", line[0..5]);
    try std.testing.expectEqualStrings("-->", line[line.len - 3 ..]);
    for (line[5 .. line.len - 1]) |byte| try std.testing.expectEqual('-', byte);
}

test "lines hands back every line at once" {
    var buffer = try Buffer.init(std.testing.allocator, "one\ntwo\nthree");
    defer buffer.deinit();

    // Puts the gap inside line 1, the case where one of them is spliced out of
    // scratch while the others point straight into the buffer.
    try buffer.insert(5, "!");

    const all = try buffer.lines();
    try std.testing.expectEqual(3, all.len);
    try std.testing.expectEqualStrings("one", all[0]);
    try std.testing.expectEqualStrings("t!wo", all[1]);
    try std.testing.expectEqualStrings("three", all[2]);
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
    try buffer.insert(1, "\u{e9}");

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
            try buffer.insert(at, text);
            try model.insertSlice(gpa, at, text);
        } else {
            const at = random.uintLessThan(usize, len);
            const count = random.uintAtMost(usize, @min(len - at, 8));
            buffer.delete(at, count);
            model.replaceRangeAssumeCapacity(at, count, "");
        }

        try std.testing.expectEqual(model.items.len, buffer.byteLen());

        const actual = try buffer.lines();
        var expected = std.mem.splitScalar(u8, model.items, '\n');
        var index: usize = 0;
        while (expected.next()) |line| : (index += 1) {
            try std.testing.expect(index < actual.len);
            try std.testing.expectEqualStrings(line, actual[index]);
        }
        try std.testing.expectEqual(index, actual.len);
    }
}

test {
    // `main` is never called in a test build, so nothing references the
    // renderer and its tests would be compiled out of the binary entirely.
    _ = @import("./renderer.zig");
}
