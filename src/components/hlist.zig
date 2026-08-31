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

        allocator: std.mem.Allocator,
        items: std.ArrayList(Member) = .empty,

        /// Which member a keystroke goes to.
        focus: usize = 0,

        /// Which member has the pointer, from a press until the release.
        holding: ?usize = null,

        /// The room the row was given. Where each column starts is worked out
        /// from it rather than remembered, so nothing has to be kept in step
        /// with the list as it grows.
        rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            for (self.items.items) |*member| member.deinit();
            self.items.deinit(self.allocator);
        }

        pub fn append(self: *Self, member: Member) !void {
            try self.items.append(self.allocator, member);
        }

        /// Puts `member` at `which`, moving the rest along. Order is what a row
        /// is, so there is no cheaper unordered version of this.
        pub fn insert(self: *Self, which: usize, member: Member) !void {
            try self.items.insert(self.allocator, which, member);
            if (self.focus >= which) self.focus += 1;
            self.holding = null;
        }

        /// Takes the member at `which` out and hands it over. Nothing here
        /// deinitialises it: a row does not know whether it is being closed or
        /// only being put away.
        pub fn remove(self: *Self, which: usize) Member {
            const gone = self.items.orderedRemove(which);
            if (self.focus > which) self.focus -= 1;
            if (self.focus >= self.items.items.len) self.focus = self.items.items.len -| 1;
            self.holding = null;
            return gone;
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

        /// Whatever it is given. How wide the columns are is a row's business;
        /// how tall they are is not, so it never asks for a height of its own.
        /// Only meaningful where a row is a member of a column.
        pub fn height(self: *const Self, atlas: *const GlyphAtlas) ?f32 {
            _ = self;
            _ = atlas;
            return null;
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
    allocator: std.mem.Allocator,
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
        try self.told.append(self.allocator, self.tag);
        return .nothing;
    }
};

fn testRow(allocator: std.mem.Allocator, told: *std.ArrayList(u8), tags: []const u8) !HList(Spy) {
    var row: HList(Spy) = .init(allocator);
    errdefer row.deinit();
    for (tags) |tag| try row.append(.{ .told = told, .allocator = allocator, .tag = tag });
    row.place(.{ .x = 0, .y = 0, .width = 100, .height = 50 }, undefined);
    return row;
}

test "however many there are, they divide the room evenly" {
    const allocator = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var three = try testRow(allocator, &told, "abc");
    defer three.deinit();

    // No seam and no overlap, and the last one ends where the row does.
    for (three.items.items[1..], three.items.items[0..2]) |right, left| {
        try std.testing.expectEqual(left.rect.x + left.rect.width, right.rect.x);
    }
    const last = three.items.items[2];
    try std.testing.expectEqual(@as(f32, 100), last.rect.x + last.rect.width);
}

test "a point lands in the column it is over, at any count" {
    const allocator = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var three = try testRow(allocator, &told, "abc");
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
    const allocator = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var two = try testRow(allocator, &told, "lr");
    defer two.deinit();

    _ = try two.update(.{ .text = "x" }, undefined);
    _ = try two.update(.{ .press = .{ 75, 10 } }, undefined);
    _ = try two.update(.{ .text = "x" }, undefined);
    try std.testing.expectEqualStrings("lrr", told.items);
    try std.testing.expectEqual(@as(usize, 1), two.focus);
}

test "a drag stays with the column it began in, and typing does not" {
    const allocator = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var two = try testRow(allocator, &told, "lr");
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
    const allocator = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var none = try testRow(allocator, &told, "");
    defer none.deinit();

    _ = try none.update(.{ .press = .{ 10, 10 } }, undefined);
    _ = try none.update(.{ .text = "x" }, undefined);
    try std.testing.expectEqualStrings("", told.items);
    try std.testing.expect(none.focused() == null);
}

test "a point outside the row is nobody's" {
    const allocator = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var two = try testRow(allocator, &told, "lr");
    defer two.deinit();

    _ = try two.update(.{ .press = .{ 400, 10 } }, undefined);
    _ = try two.update(.{ .press = .{ -5, 10 } }, undefined);
    _ = try two.update(.{ .press = .{ 50, 400 } }, undefined);
    try std.testing.expectEqualStrings("", told.items);
}
