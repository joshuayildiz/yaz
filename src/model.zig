//! The state the window is showing, and the only thing that outlives a frame.
//!
//! Handed to `place`, `update` and `draw` as the first argument rather than
//! stored: a component that kept a copy of the allocator would have a second
//! one to keep in step with this, which is the thing this is here to stop, and
//! the atlas was threaded through every one of those calls by hand.
//!
//! What a component keeps is where it drew things. What files are open, which
//! are on screen, where each caret is and whether the window is still up are
//! all here, so drawing is a matter of reading this rather than of asking
//! around.

const std = @import("std");

const GlyphAtlas = @import("./glyph_atlas.zig").GlyphAtlas;
const OpenFile = @import("./open_file.zig").OpenFile;
const tools = @import("./tools.zig");

/// The largest file yaz will open. What still costs per line of the file
/// rather than per line on screen is the layout cache, which holds a 64-byte
/// entry for each of them, and the line index behind it.
const file_limit = 1 << 20;

/// How many matches the finder shows at once. Here rather than with the panel
/// that draws them because moving the selection has to keep it on screen, and
/// that is a change to the state rather than to the drawing of it.
pub const visible_matches = 12;

/// The file finder, while it is open. Null when it is not, which is the whole
/// of what "the panel is open" means.
pub const Finding = struct {
    /// What has been typed into it.
    typed: std.ArrayList(u8) = .empty,

    /// `rg --files` verbatim, with `all` pointing into it. One allocation for
    /// the whole listing rather than one per path.
    listing: []u8 = &.{},
    all: std.ArrayList([]const u8) = .empty,

    /// `fzf --filter` verbatim, with `matches` pointing into it.
    ranked: []u8 = &.{},
    matches: std.ArrayList([]const u8) = .empty,

    /// Which match return would open, and which is the first on screen. The
    /// second follows the first rather than leading it.
    selected: usize = 0,
    top: usize = 0,

    /// What return would open.
    pub fn chosen(self: *const Finding) ?[]const u8 {
        if (self.selected >= self.matches.items.len) return null;
        return self.matches.items[self.selected];
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Owned by the renderer, which outlives everything that draws through it.
    ///
    /// Not const, and cannot be: shaping a line nobody has shaped before puts
    /// its glyphs in, so drawing a file for the first time writes here.
    ///
    /// Undefined until `run` has a window, because there is no atlas before
    /// there is one. Nothing between here and there places, draws or measures.
    atlas: *GlyphAtlas = undefined,

    /// Every file this window has open, in the order they were opened, which is
    /// also the order the bar lists them in.
    ///
    /// Owned here and nowhere else. A column points at one rather than holding
    /// it, so looking away from a file costs nothing and gives nothing up: the
    /// buffer, the line index, every line already shaped and the caret are all
    /// still here when it comes back. A file no column is pointing at is open
    /// and out of sight, which is the whole of what used to be a separate set.
    ///
    /// Boxed, because both the bar and the columns keep pointers into this and
    /// the list moves as it grows.
    files: std.ArrayList(*OpenFile) = .empty,

    /// Which files are on screen, left to right. Every one of these is in
    /// `files` as well; a file in `files` and not here is open and out of
    /// sight, which is all being "closed" ever meant short of closing.
    columns: std.ArrayList(*OpenFile) = .empty,

    /// Which column has the keyboard, and which has the pointer while a press
    /// is being held. Both are indices into `columns`.
    focus: usize = 0,
    holding: ?usize = null,

    /// Where the two tools are. Resolved once, at startup, which is also where
    /// it was settled that both of them run.
    rg: []u8 = &.{},
    fzf: []u8 = &.{},

    /// The finder, while it is open.
    finding: ?Finding = null,

    /// Whether anything above has changed since the last frame was drawn.
    ///
    /// One flag for the whole model rather than one per component: what a
    /// window has to decide is whether to draw at all, and presenting blocks,
    /// so a redundant frame costs latency rather than just work. True to begin
    /// with, since the first frame has never been drawn.
    dirty: bool = true,

    /// False ends the window. Here rather than in the loop that reads it
    /// because what decides it is a component: the last file being closed is
    /// the end of the window, and only the thing holding the files knows that.
    running: bool = true,

    /// Nothing is open yet and there is no atlas yet: the first needs the
    /// command line to have been read, the second needs a window. Both arrive
    /// through the two calls below, and nothing draws in between.
    pub fn init(process: std.process.Init) Model {
        return .{ .allocator = process.gpa, .io = process.io };
    }

    /// Every file named on the command line, in the order they were named, and
    /// a blank one when none was. Never empty, so a window always has
    /// something to show.
    ///
    /// Apart from `init` because the tool check comes between them: with
    /// ripgrep or fzf missing nothing but the healthcheck runs, and reading a
    /// file first would report the wrong problem when the path is also bad.
    pub fn openNamed(self: *Model, process: std.process.Init) !void {
        var args = try std.process.Args.Iterator.initAllocator(process.minimal.args, self.allocator);
        defer args.deinit();
        _ = args.skip(); // The program itself.

        // Read one at a time rather than gathering the paths first: the
        // iterator owns what it returns until the next call, and `open` copies
        // what it keeps.
        while (args.next()) |named| _ = try self.open(named);

        if (self.files.items.len == 0) _ = try self.blank();
    }

    /// The atlas, once there is a window to have made one. Called once, before
    /// anything is placed or drawn.
    pub fn attach(self: *Model, atlas: *GlyphAtlas) void {
        self.atlas = atlas;
    }

    /// Where ripgrep and fzf are. Both are known to run: startup refused to get
    /// this far otherwise.
    pub fn locate(self: *Model, environ: std.process.Environ) !void {
        self.rg = try tools.path(self.allocator, environ, .rg);
        self.fzf = try tools.path(self.allocator, environ, .fzf);
    }

    /// Opens the finder and reads what there is to choose between.
    pub fn find(self: *Model) !void {
        self.stopFinding();
        self.finding = .{};
        self.changed();

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ self.rg, "--files" },
            .stdout_limit = .limited(16 << 20),
        });
        defer self.allocator.free(result.stderr);
        errdefer self.allocator.free(result.stdout);

        const finding = &self.finding.?;
        finding.listing = result.stdout;
        var lines = std.mem.splitScalar(u8, finding.listing, '\n');
        while (lines.next()) |line| {
            if (line.len != 0) try finding.all.append(self.allocator, line);
        }

        try self.rank();
    }

    /// Everything that only exists while the finder is open. The listing is the
    /// one thing here that grows with the repository, so it does not outlive a
    /// closed finder.
    pub fn stopFinding(self: *Model) void {
        const finding = &(self.finding orelse return);
        finding.typed.deinit(self.allocator);
        finding.all.deinit(self.allocator);
        finding.matches.deinit(self.allocator);
        self.allocator.free(finding.listing);
        self.allocator.free(finding.ranked);
        self.finding = null;
        self.changed();
    }

    /// Adds to the query and re-ranks against it.
    pub fn typeInto(self: *Model, text: []const u8) !void {
        const finding = &(self.finding orelse return);
        try finding.typed.appendSlice(self.allocator, text);
        try self.rank();
    }

    /// Takes a character back off the query. One byte at a time is wrong the
    /// moment the query is not ASCII, and `Buffer.stepBack` is where that is
    /// already solved; this is a query, not a file, and cannot reach it.
    pub fn rubOut(self: *Model) !void {
        const finding = &(self.finding orelse return);
        if (finding.typed.items.len == 0) return;
        finding.typed.items.len -= 1;
        try self.rank();
    }

    /// Moves the selection, and the window on to it, by one.
    pub fn select(self: *Model, by: enum { up, down }) void {
        const finding = &(self.finding orelse return);
        switch (by) {
            .up => if (finding.selected > 0) {
                finding.selected -= 1;
            },
            .down => if (finding.selected + 1 < finding.matches.items.len) {
                finding.selected += 1;
            },
        }

        // Keep the selection on screen, without moving further than it has to.
        if (finding.selected < finding.top) finding.top = finding.selected;
        if (finding.selected >= finding.top + visible_matches) {
            finding.top = finding.selected + 1 - visible_matches;
        }
        self.changed();
    }

    /// Re-ranks against the query. Nothing typed is nothing offered: the whole
    /// repository is not an answer, and shaping a screenful of it would be work
    /// done on the way to being thrown away.
    fn rank(self: *Model) !void {
        const finding = &(self.finding orelse return);
        finding.matches.clearRetainingCapacity();
        finding.selected = 0;
        finding.top = 0;
        self.allocator.free(finding.ranked);
        finding.ranked = &.{};
        self.changed();

        const query = finding.typed.items;
        if (query.len == 0) return;

        const filter = try std.fmt.allocPrint(self.allocator, "--filter={s}", .{query});
        defer self.allocator.free(filter);

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
            try writer.interface.writeAll(finding.listing);
            try writer.interface.flush();
        }
        child.stdin.?.close(self.io);
        child.stdin = null;

        var buffer: [64 * 1024]u8 = undefined;
        var reader = child.stdout.?.reader(self.io, &buffer);
        finding.ranked = try reader.interface.allocRemaining(self.allocator, .limited(16 << 20));

        _ = try child.wait(self.io);

        var lines = std.mem.splitScalar(u8, finding.ranked, '\n');
        while (lines.next()) |line| {
            if (line.len != 0) try finding.matches.append(self.allocator, line);
        }
    }

    /// Says the model has moved on and the window has to be drawn again.
    pub fn changed(self: *Model) void {
        self.dirty = true;
    }

    /// What the column with the keyboard is showing, or none before there is a
    /// column. Asked rather than stored: it is `columns` and `focus`, and two
    /// facts that agree by construction cannot drift.
    pub fn showing(self: *const Model) ?*OpenFile {
        if (self.focus >= self.columns.items.len) return null;
        return self.columns.items[self.focus];
    }

    /// Whether a column is showing `file`. The bar asks this of every file it
    /// lists, which is few enough that a walk is the whole of it.
    pub fn onScreen(self: *const Model, file: *const OpenFile) bool {
        for (self.columns.items) |shown| {
            if (shown == file) return true;
        }
        return false;
    }

    /// Which column is showing `file`, if one is.
    pub fn columnOf(self: *const Model, file: *const OpenFile) ?usize {
        for (self.columns.items, 0..) |shown, which| {
            if (shown == file) return which;
        }
        return null;
    }

    pub fn deinit(self: *Model) void {
        self.stopFinding();
        self.allocator.free(self.rg);
        self.allocator.free(self.fzf);
        self.columns.deinit(self.allocator);
        for (self.files.items) |file| {
            file.deinit();
            self.allocator.destroy(file);
        }
        self.files.deinit(self.allocator);
    }

    /// The file called `path`, opened if it is not open already.
    ///
    /// Asking twice gives the same file back, which is what stops two columns
    /// showing two copies of one file that drift apart.
    pub fn open(self: *Model, path: []const u8) !*OpenFile {
        if (self.opened(path)) |already| return already;

        const text = try self.read(path);
        defer self.allocator.free(text);
        return self.hold(text, path);
    }

    /// A file nobody named, which is what a window with nothing to show has.
    pub fn blank(self: *Model) !*OpenFile {
        return self.hold("", null);
    }

    pub fn opened(self: *Model, path: []const u8) ?*OpenFile {
        for (self.files.items) |file| {
            const named = file.path orelse continue;
            if (std.mem.eql(u8, named, path)) return file;
        }
        return null;
    }

    pub fn indexOf(self: *Model, file: *const OpenFile) ?usize {
        for (self.files.items, 0..) |listed, which| {
            if (listed == file) return which;
        }
        return null;
    }

    /// Out of the window and out of memory. Closing is the one thing that means
    /// a file is finished with.
    pub fn close(self: *Model, file: *OpenFile) void {
        const which = self.indexOf(file) orelse return;
        _ = self.files.orderedRemove(which);
        file.deinit();
        self.allocator.destroy(file);
    }

    /// Every file gives up what it had shaped, for after the atlas is rebuilt
    /// at a different scale. Asked of the context rather than of the components
    /// because a file nothing is showing has a tab, and its name is glyphs of
    /// the old size too.
    pub fn invalidate(self: *Model) void {
        for (self.files.items) |file| file.invalidate();
    }

    fn hold(self: *Model, text: []const u8, path: ?[]const u8) !*OpenFile {
        const file = try self.allocator.create(OpenFile);
        errdefer self.allocator.destroy(file);

        file.* = try OpenFile.init(self.allocator, text, path);
        errdefer file.deinit();

        try self.files.append(self.allocator, file);
        return file;
    }

    fn read(self: *Model, named: []const u8) ![]u8 {
        const allocator = self.allocator;
        const path = try allocator.dupeZ(u8, named);
        defer allocator.free(path);

        const contents = std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(file_limit)) catch |err| switch (err) {
            error.FileNotFound => return allocator.alloc(u8, 0),
            error.StreamTooLong => {
                std.log.err(
                    "{s} is larger than the {d}MB yaz will open: the layout cache holds an entry for every line of it, on screen or not",
                    .{ path, file_limit >> 20 },
                );
                return error.FileTooLarge;
            },
            else => |other| {
                std.log.err("{s}: {s}", .{ path, @errorName(other) });
                return other;
            },
        };
        errdefer allocator.free(contents);

        if (firstInvalidUtf8(contents)) |offset| {
            std.log.err("{s} is not UTF-8: the byte at offset {d} does not begin or continue a character", .{ path, offset });
            return error.InvalidUtf8;
        }

        return stripCarriageReturns(allocator, contents);
    }
};

/// An offset rather than a yes or no, because the offset is the part a caller
/// can act on.
///
/// Worth refusing over rather than drawing: HarfBuzz would substitute a
/// replacement character and only look wrong, but `stepBack` walks continuation
/// bytes until it finds one that is not, so backspace over stray bytes deletes
/// however many happen to be adjacent.
fn firstInvalidUtf8(text: []const u8) ?usize {
    // Not `utf8ValidateSlice` first with this only on failure: that is two
    // pieces of code deciding what UTF-8 is, and the day they disagreed the
    // fast path would say no and this would find nothing to point at.
    var at: usize = 0;
    while (at < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[at]) catch return at;
        // Truncated: report where the sequence began, not where the bytes ran out.
        if (at + length > text.len) return at;
        _ = std.unicode.utf8Decode(text[at..][0..length]) catch return at;
        at += length;
    }
    return null;
}

test "firstInvalidUtf8 accepts what the sample file is made of" {
    try std.testing.expectEqual(@as(?usize, null), firstInvalidUtf8(""));
    try std.testing.expectEqual(@as(?usize, null), firstInvalidUtf8("plain ascii\n"));
    // Precomposed, then a combining mark, then an em dash and CJK.
    try std.testing.expectEqual(@as(?usize, null), firstInvalidUtf8("caf\u{e9} cafe\u{301} \u{2014} \u{6f22}"));
}

test "firstInvalidUtf8 points at a stray continuation byte" {
    // 0x80 continues a character that never began.
    try std.testing.expectEqual(@as(?usize, 3), firstInvalidUtf8("abc\x80def"));
}

test "firstInvalidUtf8 points at a truncated sequence" {
    // 0xE2 opens a three-byte sequence and the file ends inside it. The offset
    // is where the sequence began, not where the bytes ran out.
    try std.testing.expectEqual(@as(?usize, 2), firstInvalidUtf8("ab\xe2\x82"));
}

test "firstInvalidUtf8 rejects an overlong encoding" {
    // 0xC0 0x80 is a two-byte spelling of NUL, which is not valid UTF-8 even
    // though both bytes are individually plausible.
    try std.testing.expectEqual(@as(?usize, 0), firstInvalidUtf8("\xc0\x80"));
}

test "firstInvalidUtf8 rejects a surrogate half" {
    // ED A0 80 is U+D800, encodable as bytes but not a scalar value.
    try std.testing.expectEqual(@as(?usize, 0), firstInvalidUtf8("\xed\xa0\x80"));
}

/// Turns CRLF into LF, freeing what it is given only if it has to replace it.
///
/// A carriage return is not a line break to the line index, so it would reach
/// the shaper and set as .notdef at the end of every line. The bytes then stop
/// matching the file exactly, which is a trade to revisit when there is a way
/// to save.
fn stripCarriageReturns(allocator: std.mem.Allocator, text: []u8) ![]u8 {
    var found: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte == '\r' and i + 1 < text.len and text[i + 1] == '\n') found += 1;
    }
    if (found == 0) return text;

    const stripped = try allocator.alloc(u8, text.len - found);
    var out: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
        stripped[out] = byte;
        out += 1;
    }
    std.debug.assert(out == stripped.len);

    allocator.free(text);
    return stripped;
}

test "stripCarriageReturns leaves a file that has none alone" {
    const allocator = std.testing.allocator;
    const text = try allocator.dupe(u8, "one\ntwo\n");
    const kept = try stripCarriageReturns(allocator, text);
    defer allocator.free(kept);
    // The same allocation, not a copy of it.
    try std.testing.expectEqual(text.ptr, kept.ptr);
}

test "stripCarriageReturns turns CRLF into LF" {
    const allocator = std.testing.allocator;
    const text = try allocator.dupe(u8, "one\r\ntwo\r\n");
    const stripped = try stripCarriageReturns(allocator, text);
    defer allocator.free(stripped);
    try std.testing.expectEqualStrings("one\ntwo\n", stripped);
}

test "stripCarriageReturns keeps a carriage return that is not a line ending" {
    const allocator = std.testing.allocator;
    // A lone CR is not CRLF and is left where it is; only the pair is a line
    // ending, and a file using bare CR is not a thing this reads.
    const text = try allocator.dupe(u8, "one\rtwo\r\n");
    const stripped = try stripCarriageReturns(allocator, text);
    defer allocator.free(stripped);
    try std.testing.expectEqualStrings("one\rtwo\n", stripped);
}

test "stripCarriageReturns handles a trailing carriage return" {
    const allocator = std.testing.allocator;
    // Last byte, so there is no next one to look at; the bounds check is the
    // whole of what this is here to catch.
    const text = try allocator.dupe(u8, "one\n\r");
    const stripped = try stripCarriageReturns(allocator, text);
    defer allocator.free(stripped);
    try std.testing.expectEqualStrings("one\n\r", stripped);
}
