//! What a frame is made of, before anything is said to the GPU.
//!
//! Components draw into one of these. Each quad is added under a key saying how
//! it must be drawn, and quads sharing a key end up in one call however many
//! components produced them.

const std = @import("std");

const config = @import("./config.zig");
const Colour = config.Colour;
const Sprite = @import("./glyph_atlas.zig").Sprite;

/// Somewhere to put something, in device pixels. The window is divided into
/// these and each one is handed to whatever draws in it.
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn contains(self: Rect, point: [2]f32) bool {
        return point[0] >= self.x and point[0] < self.x + self.width and
            point[1] >= self.y and point[1] < self.y + self.height;
    }

    /// `quad` cut down to what falls inside, or null when none of it does.
    ///
    /// A `Sprite` uses one size for both the quad and the region it samples, so
    /// moving an edge moves both together and what survives samples the part of
    /// the glyph it should. The rect and the quad are both on whole pixels, so
    /// the trimmed source stays on a texel and `NEAREST` still lands dead centre.
    pub fn clip(self: Rect, quad: Sprite) ?Sprite {
        const left = @max(self.x, quad.dest[0]);
        const top = @max(self.y, quad.dest[1]);
        const right = @min(self.x + self.width, quad.dest[0] + quad.size[0]);
        const bottom = @min(self.y + self.height, quad.dest[1] + quad.size[1]);
        if (right <= left or bottom <= top) return null;

        return .{
            .dest = .{ left, top },
            .source = .{
                quad.source[0] + (left - quad.dest[0]),
                quad.source[1] + (top - quad.dest[1]),
            },
            .size = .{ right - left, bottom - top },
        };
    }
};

pub const Pipeline = enum { glyphs, solid };

/// Everything that has to be the same for two quads to be drawn in one call.
pub const Key = struct {
    /// What draws over what. Sorting is free *within* a layer, so anything that
    /// has to sit on top of something else needs a higher one -- that is the
    /// whole rule, and it is what makes reordering safe for alpha-blended quads.
    layer: u8,
    pipeline: Pipeline,
    /// A role, not an rgba: the renderer turns it into numbers against the theme
    /// as it fills each draw, so the same key reads light or dark.
    colour: Colour,

    pub fn eql(a: Key, b: Key) bool {
        return a.layer == b.layer and a.pipeline == b.pipeline and a.colour == b.colour;
    }

    /// A total order, so runs can be sorted into as few calls as possible.
    pub fn before(_: void, a: Key, b: Key) bool {
        if (a.layer != b.layer) return a.layer < b.layer;

        const ap = @intFromEnum(a.pipeline);
        const bp = @intFromEnum(b.pipeline);
        if (ap != bp) return ap < bp;

        return @intFromEnum(a.colour) < @intFromEnum(b.colour);
    }
};

/// Quads added one after another under the same key.
pub const Run = struct {
    key: Key,
    /// Where the run starts. In the painter's own quads until `Renderer.present`
    /// stages them, after which it is where the run landed on the GPU.
    first: u32,
    count: u32,
};

/// One buffer for the whole frame, and the runs that describe it.
///
/// Cleared rather than freed between frames: it settles at the size of a
/// screenful and stops allocating, which is what keeps a redraw out of the
/// allocator.
pub const Painter = struct {
    allocator: std.mem.Allocator,
    quads: std.ArrayList(Sprite) = .empty,
    runs: std.ArrayList(Run) = .empty,

    /// What everything added is cut down to. A component sets this to the room
    /// it was given, so nothing it draws can reach into anything else's.
    ///
    /// Clipped here rather than with a GPU scissor: a scissor is per draw call,
    /// and calls deliberately hold quads from several components, so scissoring
    /// would put the rect in the key and split every one of them apart again.
    clip_to: ?Rect = null,

    pub fn init(allocator: std.mem.Allocator) Painter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Painter) void {
        self.runs.deinit(self.allocator);
        self.quads.deinit(self.allocator);
    }

    pub fn clear(self: *Painter) void {
        self.quads.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
        self.clip_to = null;
    }

    pub fn clipTo(self: *Painter, rect: ?Rect) void {
        self.clip_to = rect;
    }

    /// Room for `extra` more quads, so a component drawing a screenful of them
    /// does not grow the buffer a quad at a time.
    pub fn reserve(self: *Painter, extra: usize) !void {
        try self.quads.ensureUnusedCapacity(self.allocator, extra);
    }

    /// Extends the run in progress when the key matches, and starts a new one
    /// when it does not.
    pub fn add(self: *Painter, key: Key, quad: Sprite) !void {
        const kept = if (self.clip_to) |rect| (rect.clip(quad) orelse return) else quad;
        try self.quads.append(self.allocator, kept);

        if (self.runs.items.len > 0) {
            const last = &self.runs.items[self.runs.items.len - 1];
            if (last.key.eql(key)) {
                last.count += 1;
                return;
            }
        }
        try self.runs.append(self.allocator, .{
            .key = key,
            .first = @intCast(self.quads.items.len - 1),
            .count = 1,
        });
    }
};

test "quads under one key become one run" {
    var painter: Painter = .init(std.testing.allocator);
    defer painter.deinit();

    const key: Key = .{ .layer = 0, .pipeline = .glyphs, .colour = .text };
    try painter.add(key, .solid(.{ 0, 0 }, .{ 1, 1 }));
    try painter.add(key, .solid(.{ 1, 1 }, .{ 1, 1 }));

    try std.testing.expectEqual(@as(usize, 1), painter.runs.items.len);
    try std.testing.expectEqual(@as(u32, 2), painter.runs.items[0].count);
}

test "a change of key starts a run" {
    var painter: Painter = .init(std.testing.allocator);
    defer painter.deinit();

    const text: Key = .{ .layer = 0, .pipeline = .glyphs, .colour = .text };
    const caret: Key = .{ .layer = 1, .pipeline = .solid, .colour = .text };
    try painter.add(text, .solid(.{ 0, 0 }, .{ 1, 1 }));
    try painter.add(caret, .solid(.{ 1, 1 }, .{ 1, 1 }));
    try painter.add(text, .solid(.{ 2, 2 }, .{ 1, 1 }));

    try std.testing.expectEqual(@as(usize, 3), painter.runs.items.len);
}

test "sorting gathers the runs a key belongs to" {
    const text: Key = .{ .layer = 0, .pipeline = .glyphs, .colour = .text };
    const caret: Key = .{ .layer = 1, .pipeline = .solid, .colour = .text };
    const bar: Key = .{ .layer = 2, .pipeline = .solid, .colour = .scrollbar };

    // Two components' worth, interleaved the way they would be drawn.
    var runs = [_]Run{
        .{ .key = text, .first = 0, .count = 5 },
        .{ .key = caret, .first = 5, .count = 1 },
        .{ .key = bar, .first = 6, .count = 1 },
        .{ .key = text, .first = 7, .count = 3 },
        .{ .key = caret, .first = 10, .count = 1 },
        .{ .key = bar, .first = 11, .count = 1 },
    };
    std.mem.sort(Run, &runs, {}, struct {
        fn less(_: void, a: Run, b: Run) bool {
            return Key.before({}, a.key, b.key);
        }
    }.less);

    // Six runs, but only three keys, and each key's runs are now adjacent.
    var keys: usize = 1;
    for (runs[1..], runs[0 .. runs.len - 1]) |now, then| {
        if (!now.key.eql(then.key)) keys += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), keys);
    try std.testing.expect(runs[0].key.eql(text));
    try std.testing.expect(runs[runs.len - 1].key.eql(bar));
}

test "a quad wholly inside is left alone" {
    const rect: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const quad: Sprite = .{ .dest = .{ 10, 10 }, .source = .{ 5, 5 }, .size = .{ 20, 20 } };
    const kept = rect.clip(quad).?;
    try std.testing.expectEqual(quad.dest, kept.dest);
    try std.testing.expectEqual(quad.source, kept.source);
    try std.testing.expectEqual(quad.size, kept.size);
}

test "a quad wholly outside is dropped" {
    const rect: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try std.testing.expect(rect.clip(.{ .dest = .{ 200, 0 }, .source = .{ 0, 0 }, .size = .{ 10, 10 } }) == null);
    try std.testing.expect(rect.clip(.{ .dest = .{ -20, 0 }, .source = .{ 0, 0 }, .size = .{ 10, 10 } }) == null);
}

test "clipping the right edge shortens the quad and leaves its source alone" {
    const rect: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const kept = rect.clip(.{ .dest = .{ 90, 0 }, .source = .{ 30, 40 }, .size = .{ 20, 20 } }).?;
    try std.testing.expectEqual(@as(f32, 90), kept.dest[0]);
    try std.testing.expectEqual(@as(f32, 10), kept.size[0]);
    // Nothing came off the left, so the glyph is sampled from where it was.
    try std.testing.expectEqual(@as(f32, 30), kept.source[0]);
}

test "clipping the left edge moves the source with the quad" {
    const rect: Rect = .{ .x = 100, .y = 0, .width = 100, .height = 100 };
    const kept = rect.clip(.{ .dest = .{ 94, 0 }, .source = .{ 30, 40 }, .size = .{ 20, 20 } }).?;
    try std.testing.expectEqual(@as(f32, 100), kept.dest[0]);
    try std.testing.expectEqual(@as(f32, 14), kept.size[0]);
    // Six pixels came off the left, so six texels come off the source too --
    // which is the whole reason one size can serve both.
    try std.testing.expectEqual(@as(f32, 36), kept.source[0]);
}

test "a painter clipped to a rect keeps only what falls in it" {
    var painter: Painter = .init(std.testing.allocator);
    defer painter.deinit();
    painter.clipTo(.{ .x = 0, .y = 0, .width = 100, .height = 100 });

    const key: Key = .{ .layer = 0, .pipeline = .glyphs, .colour = .text };
    try painter.add(key, .{ .dest = .{ 10, 10 }, .source = .{ 0, 0 }, .size = .{ 5, 5 } });
    try painter.add(key, .{ .dest = .{ 500, 10 }, .source = .{ 0, 0 }, .size = .{ 5, 5 } });

    try std.testing.expectEqual(@as(usize, 1), painter.quads.items.len);
    try std.testing.expectEqual(@as(u32, 1), painter.runs.items[0].count);
}
