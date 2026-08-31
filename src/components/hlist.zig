//! A row of components of one kind, however many there are.
//!
//! The counterpart of `HTuple`: that one fixes its members at compile time and
//! lets them be different things; this one fixes what they are and lets there be
//! any number of them. A window divided between however many files were named
//! is this rather than that -- the count is not known until the command line is
//! read, and every column is a view of a document.
//!
//! One member type means no selection over a tuple: reaching the nth is an
//! index. That is the whole of the difference in the code below.
//!
//! Everything else matches `HTuple`. Equal columns, all of them draw, a press
//! moves the keyboard and takes the pointer until the release, and typing goes
//! to the focused column wherever the pointer happens to be.

const std = @import("std");

const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const Intent = event_mod.Intent;

const GlyphAtlas = @import("../glyph_atlas.zig").GlyphAtlas;

const painter_mod = @import("../painter.zig");
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

pub fn HList(comptime Member: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        items: std.ArrayList(Member) = .empty,

        /// Which member a keystroke goes to.
        focus: usize = 0,

        /// Which member has the pointer, from a press until the release.
        holding: ?usize = null,

        /// The room the row was given. Where each column starts is worked out
        /// from it rather than remembered, so nothing has to be kept in step
        /// with the list as it grows.
        rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            for (self.items.items) |*member| member.deinit();
            self.items.deinit(self.gpa);
        }

        pub fn append(self: *Self, member: Member) !void {
            try self.items.append(self.gpa, member);
        }

        /// The member with the keyboard, or null while there are none.
        pub fn focused(self: *Self) ?*Member {
            if (self.focus >= self.items.items.len) return null;
            return &self.items.items[self.focus];
        }

        /// Where the `nth` column ends. Each edge from the full width rather
        /// than by adding widths up, so rounding cannot leave a seam between two
        /// columns or short of the last one -- and so that `over` can ask the
        /// same question `place` answered without either remembering.
        fn edge(self: *const Self, nth: usize) f32 {
            const count: f32 = @floatFromInt(self.items.items.len);
            return @round(self.rect.x + self.rect.width * @as(f32, @floatFromInt(nth)) / count);
        }

        pub fn place(self: *Self, rect: Rect, atlas: *const GlyphAtlas) void {
            self.rect = rect;

            var left = rect.x;
            for (self.items.items, 1..) |*member, nth| {
                const right = self.edge(nth);
                member.place(.{
                    .x = left,
                    .y = rect.y,
                    .width = right - left,
                    .height = rect.height,
                }, atlas);
                left = right;
            }
        }

        pub fn isDirty(self: *const Self) bool {
            for (self.items.items) |*member| {
                if (member.isDirty()) return true;
            }
            return false;
        }

        pub fn setDirty(self: *Self, value: bool) void {
            for (self.items.items) |*member| member.setDirty(value);
        }

        pub fn invalidate(self: *Self) void {
            for (self.items.items) |*member| member.invalidate();
        }

        pub fn draw(self: *Self, atlas: *GlyphAtlas, painter: *Painter) !void {
            for (self.items.items) |*member| try member.draw(atlas, painter);
        }

        pub fn update(self: *Self, event: Event, atlas: *GlyphAtlas) !Intent {
            switch (event) {
                .press => |at| {
                    const which = self.over(at) orelse return .nothing;
                    self.focus = which;
                    self.holding = which;
                    return self.items.items[which].update(event, atlas);
                },
                .move => |at| {
                    const which = self.holding orelse self.over(at) orelse return .nothing;
                    return self.items.items[which].update(event, atlas);
                },
                .release => {
                    const which = self.holding orelse return .nothing;
                    self.holding = null;
                    return self.items.items[which].update(event, atlas);
                },
                .wheel => |wheel| {
                    const which = self.over(wheel.at) orelse return .nothing;
                    return self.items.items[which].update(event, atlas);
                },
                else => {
                    const member = self.focused() orelse return .nothing;
                    return member.update(event, atlas);
                },
            }
        }

        /// Which column a point falls in. They do not overlap, so at most one
        /// can answer.
        fn over(self: *const Self, at: [2]f32) ?usize {
            if (at[1] < self.rect.y or at[1] >= self.rect.y + self.rect.height) return null;
            if (at[0] < self.rect.x) return null;
            for (0..self.items.items.len) |which| {
                if (at[0] < self.edge(which + 1)) return which;
            }
            return null;
        }
    };
}

/// A member that records the room it was given and what it was told, so routing
/// can be checked without a window or a font.
const Spy = struct {
    told: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    tag: u8,
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(_: *Spy) void {}
    pub fn isDirty(_: *const Spy) bool {
        return false;
    }
    pub fn setDirty(_: *Spy, _: bool) void {}
    pub fn invalidate(_: *Spy) void {}
    pub fn draw(_: *Spy, _: *GlyphAtlas, _: *Painter) !void {}

    pub fn place(self: *Spy, rect: Rect, _: *const GlyphAtlas) void {
        self.rect = rect;
    }

    pub fn update(self: *Spy, _: Event, _: *GlyphAtlas) !Intent {
        try self.told.append(self.gpa, self.tag);
        return .nothing;
    }
};

fn testRow(gpa: std.mem.Allocator, told: *std.ArrayList(u8), tags: []const u8) !HList(Spy) {
    var row: HList(Spy) = .init(gpa);
    errdefer row.deinit();
    for (tags) |tag| try row.append(.{ .told = told, .gpa = gpa, .tag = tag });
    row.place(.{ .x = 0, .y = 0, .width = 100, .height = 50 }, undefined);
    return row;
}

test "however many there are, they divide the room evenly" {
    const gpa = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(gpa);

    var three = try testRow(gpa, &told, "abc");
    defer three.deinit();

    // No seam and no overlap, and the last one ends where the row does.
    for (three.items.items[1..], three.items.items[0..2]) |right, left| {
        try std.testing.expectEqual(left.rect.x + left.rect.width, right.rect.x);
    }
    const last = three.items.items[2];
    try std.testing.expectEqual(@as(f32, 100), last.rect.x + last.rect.width);
}

test "a point lands in the column it is over, at any count" {
    const gpa = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(gpa);

    var three = try testRow(gpa, &told, "abc");
    defer three.deinit();

    _ = try three.update(.{ .press = .{ 10, 10 } }, undefined);
    _ = try three.update(.{ .press = .{ 50, 10 } }, undefined);
    _ = try three.update(.{ .press = .{ 90, 10 } }, undefined);
    // The first edge lands on 33, and a boundary belongs to the column on its
    // right: 32 is the last pixel of the first column, 33 the first of the next.
    _ = try three.update(.{ .press = .{ 32, 10 } }, undefined);
    _ = try three.update(.{ .press = .{ 33, 10 } }, undefined);
    try std.testing.expectEqualStrings("abcab", told.items);
}

test "a press moves the keyboard and typing follows it" {
    const gpa = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(gpa);

    var two = try testRow(gpa, &told, "lr");
    defer two.deinit();

    _ = try two.update(.{ .text = "x" }, undefined);
    _ = try two.update(.{ .press = .{ 75, 10 } }, undefined);
    _ = try two.update(.{ .text = "x" }, undefined);
    try std.testing.expectEqualStrings("lrr", told.items);
    try std.testing.expectEqual(@as(usize, 1), two.focus);
}

test "a drag stays with the column it began in, and typing does not" {
    const gpa = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(gpa);

    var two = try testRow(gpa, &told, "lr");
    defer two.deinit();

    // Keyboard on the right, drag started on the left.
    _ = try two.update(.{ .press = .{ 75, 10 } }, undefined);
    _ = try two.update(.{ .press = .{ 10, 10 } }, undefined);
    two.focus = 1;
    told.clearRetainingCapacity();

    _ = try two.update(.{ .move = .{ 75, 10 } }, undefined);
    _ = try two.update(.{ .text = "x" }, undefined);
    _ = try two.update(.release, undefined);
    _ = try two.update(.{ .move = .{ 75, 10 } }, undefined);

    // Move to the drag, character to the keyboard, release to the drag, and the
    // next move to whatever it is over.
    try std.testing.expectEqualStrings("lrlr", told.items);
}

test "an empty row has nothing to be over and nothing to type into" {
    const gpa = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(gpa);

    var none = try testRow(gpa, &told, "");
    defer none.deinit();

    _ = try none.update(.{ .press = .{ 10, 10 } }, undefined);
    _ = try none.update(.{ .text = "x" }, undefined);
    try std.testing.expectEqualStrings("", told.items);
    try std.testing.expect(none.focused() == null);
}

test "a point outside the row is nobody's" {
    const gpa = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(gpa);

    var two = try testRow(gpa, &told, "lr");
    defer two.deinit();

    _ = try two.update(.{ .press = .{ 400, 10 } }, undefined);
    _ = try two.update(.{ .press = .{ -5, 10 } }, undefined);
    _ = try two.update(.{ .press = .{ 50, 400 } }, undefined);
    try std.testing.expectEqualStrings("", told.items);
}
