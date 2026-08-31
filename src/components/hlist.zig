//! A row of components of one kind, however many there are.
//!
//! The counterpart of `HTuple`: that one fixes its members at compile time and
//! lets them be different things; this one fixes what they are and lets there be
//! any number of them. A window divided between however many files were named
//! is this rather than that -- the count is not known until the command line is
//! read, and every column is a view of a file.
//!
//! One member type means no selection over a tuple: reaching the nth is an
//! index. That is the whole of the difference in the code below.
//!
//! Everything else matches `HTuple`. Equal columns, all of them draw, a press
//! moves the keyboard and takes the pointer until the release, and typing goes
//! to the focused column wherever the pointer happens to be.

const std = @import("std");

const message_mod = @import("../message.zig");
const Message = message_mod.Message;
const Intent = message_mod.Intent;

const GlyphAtlas = @import("../glyph_atlas.zig").GlyphAtlas;
const Model = @import("../model.zig").Model;

const painter_mod = @import("../painter.zig");
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

pub fn HList(comptime Member: type) type {
    return struct {
        const Self = @This();

        items: std.ArrayList(Member) = .empty,

        /// Which member a keystroke goes to.
        focus: usize = 0,

        /// Which member has the pointer, from a press until the release.
        holding: ?usize = null,

        /// The room the row was given. Where each column starts is worked out
        /// from it rather than remembered, so nothing has to be kept in step
        /// with the list as it grows.
        rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

        pub fn deinit(self: *Self, model: *Model) void {
            for (self.items.items) |*member| member.deinit(model);
            self.items.deinit(model.allocator);
        }

        pub fn append(self: *Self, model: *Model, member: Member) !void {
            try self.items.append(model.allocator, member);
        }

        /// Puts `member` at `which`, moving the rest along. Order is what a row
        /// is, so there is no cheaper unordered version of this.
        pub fn insert(self: *Self, model: *Model, which: usize, member: Member) !void {
            try self.items.insert(model.allocator, which, member);
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
        pub fn height(self: *const Self, model: *Model) ?f32 {
            _ = self;
            _ = model.atlas;
            return null;
        }

        pub fn place(self: *Self, model: *Model, rect: Rect) void {
            self.rect = rect;

            var left = rect.x;
            for (self.items.items, 1..) |*member, nth| {
                const right = self.edge(nth);
                member.place(model, .{
                    .x = left,
                    .y = rect.y,
                    .width = right - left,
                    .height = rect.height,
                });
                left = right;
            }
        }

        pub fn invalidate(self: *Self) void {
            for (self.items.items) |*member| member.invalidate();
        }

        pub fn draw(self: *Self, model: *Model, painter: *Painter) !void {
            for (self.items.items) |*member| try member.draw(model, painter);
        }

        pub fn update(self: *Self, model: *Model, message: Message) !Intent {
            switch (message) {
                .press => |at| {
                    const which = self.over(at) orelse return .nothing;
                    self.focus = which;
                    self.holding = which;
                    return self.items.items[which].update(model, message);
                },
                .move => |at| {
                    const which = self.holding orelse self.over(at) orelse return .nothing;
                    return self.items.items[which].update(model, message);
                },
                .release => {
                    const which = self.holding orelse return .nothing;
                    self.holding = null;
                    return self.items.items[which].update(model, message);
                },
                .wheel => |wheel| {
                    const which = self.over(wheel.at) orelse return .nothing;
                    return self.items.items[which].update(model, message);
                },
                else => {
                    const member = self.focused() orelse return .nothing;
                    return member.update(model, message);
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
    tag: u8,
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(_: *Spy, _: *Model) void {}
    pub fn invalidate(_: *Spy) void {}
    pub fn draw(_: *Spy, _: *Model, _: *Painter) !void {}

    pub fn place(self: *Spy, _: *Model, rect: Rect) void {
        self.rect = rect;
    }

    pub fn update(self: *Spy, model: *Model, _: Message) !Intent {
        try self.told.append(model.allocator, self.tag);
        return .nothing;
    }
};

fn testRow(model: *Model, told: *std.ArrayList(u8), tags: []const u8) !HList(Spy) {
    var row: HList(Spy) = .{};
    errdefer row.deinit(model);
    for (tags) |tag| try row.append(model, .{ .told = told, .tag = tag });
    row.place(model, .{ .x = 0, .y = 0, .width = 100, .height = 50 });
    return row;
}

fn testModel(allocator: std.mem.Allocator) Model {
    return .{ .allocator = allocator, .io = undefined };
}

test "however many there are, they divide the room evenly" {
    const allocator = std.testing.allocator;
    var model = testModel(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var three = try testRow(&model, &told, "abc");
    defer three.deinit(&model);

    // No seam and no overlap, and the last one ends where the row does.
    for (three.items.items[1..], three.items.items[0..2]) |right, left| {
        try std.testing.expectEqual(left.rect.x + left.rect.width, right.rect.x);
    }
    const last = three.items.items[2];
    try std.testing.expectEqual(@as(f32, 100), last.rect.x + last.rect.width);
}

test "a point lands in the column it is over, at any count" {
    const allocator = std.testing.allocator;
    var model = testModel(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var three = try testRow(&model, &told, "abc");
    defer three.deinit(&model);

    _ = try three.update(&model, .{ .press = .{ 10, 10 } });
    _ = try three.update(&model, .{ .press = .{ 50, 10 } });
    _ = try three.update(&model, .{ .press = .{ 90, 10 } });
    // The first edge lands on 33, and a boundary belongs to the column on its
    // right: 32 is the last pixel of the first column, 33 the first of the next.
    _ = try three.update(&model, .{ .press = .{ 32, 10 } });
    _ = try three.update(&model, .{ .press = .{ 33, 10 } });
    try std.testing.expectEqualStrings("abcab", told.items);
}

test "a press moves the keyboard and typing follows it" {
    const allocator = std.testing.allocator;
    var model = testModel(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var two = try testRow(&model, &told, "lr");
    defer two.deinit(&model);

    _ = try two.update(&model, .{ .text = "x" });
    _ = try two.update(&model, .{ .press = .{ 75, 10 } });
    _ = try two.update(&model, .{ .text = "x" });
    try std.testing.expectEqualStrings("lrr", told.items);
    try std.testing.expectEqual(@as(usize, 1), two.focus);
}

test "a drag stays with the column it began in, and typing does not" {
    const allocator = std.testing.allocator;
    var model = testModel(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var two = try testRow(&model, &told, "lr");
    defer two.deinit(&model);

    // Keyboard on the right, drag started on the left.
    _ = try two.update(&model, .{ .press = .{ 75, 10 } });
    _ = try two.update(&model, .{ .press = .{ 10, 10 } });
    two.focus = 1;
    told.clearRetainingCapacity();

    _ = try two.update(&model, .{ .move = .{ 75, 10 } });
    _ = try two.update(&model, .{ .text = "x" });
    _ = try two.update(&model, .release);
    _ = try two.update(&model, .{ .move = .{ 75, 10 } });

    // Move to the drag, character to the keyboard, release to the drag, and the
    // next move to whatever it is over.
    try std.testing.expectEqualStrings("lrlr", told.items);
}

test "an empty row has nothing to be over and nothing to type into" {
    const allocator = std.testing.allocator;
    var model = testModel(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var none = try testRow(&model, &told, "");
    defer none.deinit(&model);

    _ = try none.update(&model, .{ .press = .{ 10, 10 } });
    _ = try none.update(&model, .{ .text = "x" });
    try std.testing.expectEqualStrings("", told.items);
    try std.testing.expect(none.focused() == null);
}

test "a point outside the row is nobody's" {
    const allocator = std.testing.allocator;
    var model = testModel(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var two = try testRow(&model, &told, "lr");
    defer two.deinit(&model);

    _ = try two.update(&model, .{ .press = .{ 400, 10 } });
    _ = try two.update(&model, .{ .press = .{ -5, 10 } });
    _ = try two.update(&model, .{ .press = .{ 50, 400 } });
    try std.testing.expectEqualStrings("", told.items);
}
