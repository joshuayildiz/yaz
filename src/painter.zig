//! What a frame is made of, before anything is said to the GPU.
//!
//! Components draw into one of these. Each quad is added under a key saying how
//! it must be drawn, and quads sharing a key end up in one call however many
//! components produced them.

const std = @import("std");

const Sprite = @import("./glyph_atlas.zig").Sprite;

/// Somewhere to put something, in device pixels. The window is divided into
/// these and each one is handed to whatever draws in it.
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

};

pub const Pipeline = enum { glyphs, solid };

/// Everything that has to be the same for two quads to be drawn in one call.
pub const Key = struct {
    /// What draws over what. Sorting is free *within* a layer, so anything that
    /// has to sit on top of something else needs a higher one -- that is the
    /// whole rule, and it is what makes reordering safe for alpha-blended quads.
    layer: u8,
    pipeline: Pipeline,
    colour: [4]f32,

    pub fn eql(a: Key, b: Key) bool {
        return a.layer == b.layer and a.pipeline == b.pipeline and
            std.mem.eql(f32, &a.colour, &b.colour);
    }

    /// A total order, so runs can be sorted into as few calls as possible.
    pub fn before(_: void, a: Key, b: Key) bool {
        if (a.layer != b.layer) return a.layer < b.layer;

        const ap = @intFromEnum(a.pipeline);
        const bp = @intFromEnum(b.pipeline);
        if (ap != bp) return ap < bp;

        for (a.colour, b.colour) |x, y| {
            if (x != y) return x < y;
        }
        return false;
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
    gpa: std.mem.Allocator,
    quads: std.ArrayList(Sprite) = .empty,
    runs: std.ArrayList(Run) = .empty,

    pub fn init(gpa: std.mem.Allocator) Painter {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Painter) void {
        self.runs.deinit(self.gpa);
        self.quads.deinit(self.gpa);
    }

    pub fn clear(self: *Painter) void {
        self.quads.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
    }

    /// Room for `extra` more quads, so a component drawing a screenful of them
    /// does not grow the buffer a quad at a time.
    pub fn reserve(self: *Painter, extra: usize) !void {
        try self.quads.ensureUnusedCapacity(self.gpa, extra);
    }

    /// Extends the run in progress when the key matches, and starts a new one
    /// when it does not.
    pub fn add(self: *Painter, key: Key, quad: Sprite) !void {
        try self.quads.append(self.gpa, quad);

        if (self.runs.items.len > 0) {
            const last = &self.runs.items[self.runs.items.len - 1];
            if (last.key.eql(key)) {
                last.count += 1;
                return;
            }
        }
        try self.runs.append(self.gpa, .{
            .key = key,
            .first = @intCast(self.quads.items.len - 1),
            .count = 1,
        });
    }
};

test "quads under one key become one run" {
    var painter: Painter = .init(std.testing.allocator);
    defer painter.deinit();

    const key: Key = .{ .layer = 0, .pipeline = .glyphs, .colour = .{ 0, 0, 0, 1 } };
    try painter.add(key, .solid(.{ 0, 0 }, .{ 1, 1 }));
    try painter.add(key, .solid(.{ 1, 1 }, .{ 1, 1 }));

    try std.testing.expectEqual(@as(usize, 1), painter.runs.items.len);
    try std.testing.expectEqual(@as(u32, 2), painter.runs.items[0].count);
}

test "a change of key starts a run" {
    var painter: Painter = .init(std.testing.allocator);
    defer painter.deinit();

    const text: Key = .{ .layer = 0, .pipeline = .glyphs, .colour = .{ 0, 0, 0, 1 } };
    const caret: Key = .{ .layer = 1, .pipeline = .solid, .colour = .{ 0, 0, 0, 1 } };
    try painter.add(text, .solid(.{ 0, 0 }, .{ 1, 1 }));
    try painter.add(caret, .solid(.{ 1, 1 }, .{ 1, 1 }));
    try painter.add(text, .solid(.{ 2, 2 }, .{ 1, 1 }));

    try std.testing.expectEqual(@as(usize, 3), painter.runs.items.len);
}

test "sorting gathers the runs a key belongs to" {
    const text: Key = .{ .layer = 0, .pipeline = .glyphs, .colour = .{ 0, 0, 0, 1 } };
    const caret: Key = .{ .layer = 1, .pipeline = .solid, .colour = .{ 0, 0, 0, 1 } };
    const bar: Key = .{ .layer = 2, .pipeline = .solid, .colour = .{ 0, 0, 0, 0.28 } };

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
