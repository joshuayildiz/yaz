//! A column of components, top to bottom.
//!
//! The third of the three, and the one whose members are not all the same size:
//! a `ZStack` gives every member the whole rect, an `HStack` divides it evenly,
//! and here each member says how tall it wants to be. One that says nothing
//! takes what is left, which is how a list under a heading gets the rest of the
//! window without either of them knowing the window's size.
//!
//! The atlas comes with the rect because a height is nearly always a number of
//! lines, and what a line is worth is a property of the font at the display's
//! scale rather than of the layout.
//!
//! All of them draw, since none covers another. A press moves the keyboard and
//! takes the pointer until the release, as in `HStack`.

const std = @import("std");

const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const Intent = event_mod.Intent;

const GlyphAtlas = @import("../glyph_atlas.zig").GlyphAtlas;

const painter_mod = @import("../painter.zig");
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

/// `members` are listed top to bottom. Each answers `height` with what it wants,
/// or null to take a share of whatever is left over.
pub fn VStack(comptime members: []const type) type {
    return struct {
        const Self = @This();
        pub const count = members.len;

        items: std.meta.Tuple(members),

        /// Which member a keystroke goes to.
        focus: usize = 0,

        /// Which member has the pointer, from a press until the release.
        holding: ?usize = null,

        /// What each member was given, so a point can be turned back into the
        /// member it fell in.
        rects: [count]Rect = empty: {
            var none: [count]Rect = undefined;
            for (&none) |*rect| rect.* = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            break :empty none;
        },

        pub fn init(items: std.meta.Tuple(members)) Self {
            return .{ .items = items };
        }

        pub fn deinit(self: *Self) void {
            inline for (0..count) |i| self.items[i].deinit();
        }

        pub fn has(comptime T: type) bool {
            inline for (members) |member| {
                if (member == T) return true;
            }
            return false;
        }

        pub fn get(self: *Self, comptime T: type) *T {
            return &self.items[comptime indexOf(T)];
        }

        /// The member with the keyboard, when it is a `T`.
        pub fn focused(self: *Self, comptime T: type) ?*T {
            inline for (0..count) |i| {
                if (comptime members[i] == T) {
                    if (self.focus == i) return &self.items[i];
                }
            }
            return null;
        }

        fn indexOf(comptime T: type) usize {
            inline for (members, 0..) |member, i| {
                if (member == T) return i;
            }
            @compileError(@typeName(T) ++ " is not in this column");
        }

        /// Asks every member how tall it wants to be, hands what is left to the
        /// ones that did not say, and places them from the top.
        pub fn place(self: *Self, rect: Rect, atlas: *const GlyphAtlas) void {
            var asked: [count]?f32 = undefined;
            var spoken: f32 = 0;
            var quiet: usize = 0;
            inline for (0..count) |i| {
                asked[i] = self.items[i].height(atlas);
                if (asked[i]) |want| spoken += want else quiet += 1;
            }

            const spare = if (quiet == 0) 0 else @max(0, rect.height - spoken) / @as(f32, @floatFromInt(quiet));

            // Each edge is rounded off a running total rather than each height
            // being rounded on its own, so the bands meet exactly and the last
            // one ends where the rect does.
            var top = rect.y;
            inline for (0..count) |i| {
                const want = asked[i] orelse spare;
                const y = @round(top);
                const bottom = @round(top + want);
                self.rects[i] = .{ .x = rect.x, .y = y, .width = rect.width, .height = bottom - y };
                self.items[i].place(self.rects[i], atlas);
                top += want;
            }
        }

        pub fn isDirty(self: *const Self) bool {
            inline for (0..count) |i| {
                if (self.items[i].isDirty()) return true;
            }
            return false;
        }

        pub fn setDirty(self: *Self, value: bool) void {
            inline for (0..count) |i| self.items[i].setDirty(value);
        }

        pub fn invalidate(self: *Self) void {
            inline for (0..count) |i| self.items[i].invalidate();
        }

        pub fn draw(self: *Self, atlas: *GlyphAtlas, painter: *Painter) !void {
            inline for (0..count) |i| try self.items[i].draw(atlas, painter);
        }

        pub fn update(self: *Self, event: Event, atlas: *GlyphAtlas) !Intent {
            switch (event) {
                .press => |at| {
                    const which = self.over(at) orelse return .nothing;
                    self.focus = which;
                    self.holding = which;
                    return self.tell(which, event, atlas);
                },
                .move => |at| return self.tell(self.holding orelse self.over(at) orelse return .nothing, event, atlas),
                .release => {
                    const which = self.holding orelse return .nothing;
                    self.holding = null;
                    return self.tell(which, event, atlas);
                },
                .wheel => |wheel| return self.tell(self.over(wheel.at) orelse return .nothing, event, atlas),
                else => return self.tell(self.focus, event, atlas),
            }
        }

        /// Which member a point falls in. The bands do not overlap, so at most
        /// one can answer.
        fn over(self: *const Self, at: [2]f32) ?usize {
            for (self.rects, 0..) |rect, which| {
                if (rect.contains(at)) return which;
            }
            return null;
        }

        fn tell(self: *Self, which: usize, event: Event, atlas: *GlyphAtlas) !Intent {
            inline for (0..count) |i| {
                if (which == i) return self.items[i].update(event, atlas);
            }
            unreachable;
        }
    };
}

/// A member that wants `wants` pixels, or all it can get when that is null.
fn Band(comptime tag: u8, comptime wants: ?f32) type {
    return struct {
        const Self = @This();
        told: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
        rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

        pub fn deinit(_: *Self) void {}
        pub fn isDirty(_: *const Self) bool {
            return false;
        }
        pub fn setDirty(_: *Self, _: bool) void {}
        pub fn invalidate(_: *Self) void {}
        pub fn draw(_: *Self, _: *GlyphAtlas, _: *Painter) !void {}

        pub fn height(_: *const Self, _: *const GlyphAtlas) ?f32 {
            return wants;
        }

        pub fn place(self: *Self, rect: Rect, _: *const GlyphAtlas) void {
            self.rect = rect;
        }

        pub fn update(self: *Self, _: Event, _: *GlyphAtlas) !Intent {
            try self.told.append(self.gpa, tag);
            return .nothing;
        }
    };
}

const Heading = Band('h', 20);
const List = Band('l', null);
const Footer = Band('f', 10);

test "a member that says nothing takes what is left" {
    const gpa = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(gpa);

    var column: VStack(&.{ Heading, List, Footer }) = .init(.{
        .{ .told = &told, .gpa = gpa },
        .{ .told = &told, .gpa = gpa },
        .{ .told = &told, .gpa = gpa },
    });
    column.place(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, undefined);

    try std.testing.expectEqual(@as(f32, 0), column.items[0].rect.y);
    try std.testing.expectEqual(@as(f32, 20), column.items[0].rect.height);
    // 100 less the 20 and the 10 that were asked for.
    try std.testing.expectEqual(@as(f32, 20), column.items[1].rect.y);
    try std.testing.expectEqual(@as(f32, 70), column.items[1].rect.height);
    try std.testing.expectEqual(@as(f32, 90), column.items[2].rect.y);
    try std.testing.expectEqual(@as(f32, 10), column.items[2].rect.height);
}

test "the bands meet exactly, whatever the fractions" {
    const gpa = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(gpa);

    const Thirds = Band('t', 33.4);
    var column: VStack(&.{ Thirds, Thirds, List }) = .init(.{
        .{ .told = &told, .gpa = gpa },
        .{ .told = &told, .gpa = gpa },
        .{ .told = &told, .gpa = gpa },
    });
    column.place(.{ .x = 0, .y = 5, .width = 100, .height = 100 }, undefined);

    // No seam and no overlap: each band starts where the one above it ended.
    for (column.rects[1..], column.rects[0 .. column.rects.len - 1]) |below, above| {
        try std.testing.expectEqual(above.y + above.height, below.y);
    }
    // And the column ends where the rect does.
    const last = column.rects[column.rects.len - 1];
    try std.testing.expectEqual(@as(f32, 105), last.y + last.height);
}

test "a column with nothing spare does not stretch anyone" {
    const gpa = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(gpa);

    var column: VStack(&.{ Heading, Footer }) = .init(.{
        .{ .told = &told, .gpa = gpa },
        .{ .told = &told, .gpa = gpa },
    });
    column.place(.{ .x = 0, .y = 0, .width = 100, .height = 500 }, undefined);

    try std.testing.expectEqual(@as(f32, 20), column.items[0].rect.height);
    try std.testing.expectEqual(@as(f32, 10), column.items[1].rect.height);
}

test "asking for more than there is leaves nothing spare rather than a negative band" {
    const gpa = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(gpa);

    var column: VStack(&.{ Heading, List }) = .init(.{
        .{ .told = &told, .gpa = gpa },
        .{ .told = &told, .gpa = gpa },
    });
    column.place(.{ .x = 0, .y = 0, .width = 100, .height = 8 }, undefined);

    try std.testing.expectEqual(@as(f32, 0), column.items[1].rect.height);
}

test "a press moves the keyboard down the column and typing follows it" {
    const gpa = std.testing.allocator;
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(gpa);

    var column: VStack(&.{ Heading, List }) = .init(.{
        .{ .told = &told, .gpa = gpa },
        .{ .told = &told, .gpa = gpa },
    });
    column.place(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, undefined);

    _ = try column.update(.{ .text = "a" }, undefined);
    _ = try column.update(.{ .press = .{ 10, 50 } }, undefined);
    _ = try column.update(.{ .text = "b" }, undefined);

    try std.testing.expectEqualStrings("hll", told.items);
    try std.testing.expectEqual(@as(usize, 1), column.focus);
}
