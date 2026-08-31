//! What every component is given.
//!
//! Handed to `place`, `update` and `draw` as the first argument rather than
//! stored: a component that kept a copy of the allocator would have a second
//! one to keep in step with this, which is the thing this is here to stop. The
//! atlas is here for the same reason -- it was threaded through every one of
//! those calls by hand.

const std = @import("std");

const GlyphAtlas = @import("./glyph_atlas.zig").GlyphAtlas;
const OpenFile = @import("./open_file.zig").OpenFile;

/// The largest file yaz will open. What still costs per line of the file
/// rather than per line on screen is the layout cache, which holds a 64-byte
/// entry for each of them, and the line index behind it.
const file_limit = 1 << 20;

pub const Context = struct {
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

    /// False ends the window. Here rather than in the loop that reads it
    /// because what decides it is a component: the last file being closed is
    /// the end of the window, and only the thing holding the files knows that.
    running: bool = true,

    pub fn deinit(self: *Context) void {
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
    pub fn open(self: *Context, path: []const u8) !*OpenFile {
        if (self.find(path)) |already| return already;

        const text = try self.read(path);
        defer self.allocator.free(text);
        return self.hold(text, path);
    }

    /// A file nobody named, which is what a window with nothing to show has.
    pub fn blank(self: *Context) !*OpenFile {
        return self.hold("", null);
    }

    pub fn find(self: *Context, path: []const u8) ?*OpenFile {
        for (self.files.items) |file| {
            const named = file.path orelse continue;
            if (std.mem.eql(u8, named, path)) return file;
        }
        return null;
    }

    pub fn indexOf(self: *Context, file: *const OpenFile) ?usize {
        for (self.files.items, 0..) |listed, which| {
            if (listed == file) return which;
        }
        return null;
    }

    /// Out of the window and out of memory. Closing is the one thing that means
    /// a file is finished with.
    pub fn close(self: *Context, file: *OpenFile) void {
        const which = self.indexOf(file) orelse return;
        _ = self.files.orderedRemove(which);
        file.deinit();
        self.allocator.destroy(file);
    }

    /// Every file gives up what it had shaped, for after the atlas is rebuilt
    /// at a different scale. Asked of the context rather than of the components
    /// because a file nothing is showing has a tab, and its name is glyphs of
    /// the old size too.
    pub fn invalidate(self: *Context) void {
        for (self.files.items) |file| file.invalidate();
    }

    fn hold(self: *Context, text: []const u8, path: ?[]const u8) !*OpenFile {
        const file = try self.allocator.create(OpenFile);
        errdefer self.allocator.destroy(file);

        file.* = try OpenFile.init(self.allocator, text, path);
        errdefer file.deinit();

        try self.files.append(self.allocator, file);
        return file;
    }

    fn read(self: *Context, named: []const u8) ![]u8 {
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
