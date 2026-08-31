//! What every component is given.
//!
//! Handed to `place`, `update` and `draw` as the first argument rather than
//! stored: a component that kept a copy of the allocator would have a second
//! one to keep in step with this, which is the thing this is here to stop. The
//! atlas is here for the same reason -- it was threaded through every one of
//! those calls by hand.

const std = @import("std");

const GlyphAtlas = @import("./glyph_atlas.zig").GlyphAtlas;
const Document = @import("./document.zig").Document;

/// The largest file yaz will open. What still costs per line of the document
/// rather than per line on screen is the layout cache, which holds a 64-byte
/// entry for each of them, and the line index behind it.
const file_limit = 1 << 20;

/// Both fields are owned by the caller. `path` is null when nothing was named,
/// which is not the same as a file that turned out to be empty.
pub const Opened = struct {
    text: []u8,
    /// Sentinel-terminated because it goes to SDL as a window title.
    path: ?[:0]u8,

    pub fn deinit(self: *Opened, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.path) |path| allocator.free(path);
    }
};

/// Where a reader was in a file: what the caret was on, and what was on screen.
///
/// Kept by whoever outlives the view, since a view shows one file at a time and
/// this is the half of the last one that the document itself does not hold.
pub const Position = struct {
    cursor: usize,
    scroll: f32,
};

/// What a view was showing before it was pointed somewhere else. The caller owns
/// all of it, and can hand the document straight back later rather than reading
/// the file again.
pub const Retired = struct {
    document: Document,
    path: ?[]u8,
    position: Position,
};

/// A file that is in memory but not on screen, and where its reader was in it.
pub const Parked = struct {
    document: Document,
    position: Position,

    /// By path, which is what the finder answers with. Keys are owned, and a
    /// document is either in here or in exactly one view, never both.
    pub const Map = std.StringHashMapUnmanaged(Parked);
};

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

    /// Files that have been looked at and are not on screen now.
    ///
    /// Kept whole rather than re-read: a document is a buffer, a line index and
    /// every line already shaped, and looking away from a file is no reason to
    /// throw that away and pay for it again on the way back.
    parked: Parked.Map = .empty,

    /// False ends the window. Here rather than in the loop that reads it
    /// because what decides it is a component: the last file being closed is
    /// the end of the window, and only the thing holding the files knows that.
    running: bool = true,

    pub fn deinit(self: *Context) void {
        var resting = self.parked.iterator();
        while (resting.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.document.deinit();
        }
        self.parked.deinit(self.allocator);
    }

    /// Keeps what a view was showing, against being asked for it again.
    pub fn park(self: *Context, retired: Retired) !void {
        var leaving = retired;

        const path = leaving.path orelse {
            // A document nobody named cannot be asked for by name.
            leaving.document.deinit();
            return;
        };
        errdefer {
            self.allocator.free(path);
            leaving.document.deinit();
        }

        const slot = try self.parked.getOrPut(self.allocator, path);
        if (slot.found_existing) {
            // Keep what was just put down.
            slot.value_ptr.document.deinit();
            self.allocator.free(path);
        } else {
            slot.key_ptr.* = path;
        }
        slot.value_ptr.* = .{ .document = leaving.document, .position = leaving.position };
    }

    /// Takes a file back out, with the key freed and the document handed over.
    /// Null when it has not been looked at, which means it has to be read.
    pub fn unpark(self: *Context, path: []const u8) ?Parked {
        const entry = self.parked.fetchRemove(path) orelse return null;
        self.allocator.free(entry.key);
        return entry.value;
    }

    /// Reads one named file.
    ///
    /// A path that does not exist opens empty under that name, the way a new file
    /// starts. Anything else stops the program: an empty window otherwise looks
    /// exactly like an empty file.
    pub fn read(self: *Context, named: []const u8) !Opened {
        const allocator = self.allocator;
        const path = try allocator.dupeZ(u8, named);
        errdefer allocator.free(path);

        const contents = std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(file_limit)) catch |err| switch (err) {
            error.FileNotFound => return .{ .text = try allocator.alloc(u8, 0), .path = path },
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

        return .{ .text = try stripCarriageReturns(allocator, contents), .path = path };
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
