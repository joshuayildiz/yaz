//! A column of components, top to bottom, whose members are not all the same
//! size.
//!
//! Each member says how tall it wants to be, and one that says nothing takes
//! what is left -- which is how a list under a heading gets the rest of the
//! window without either of them knowing the window's size. The atlas comes
//! with the rect because a height is nearly always a number of lines, and what
//! a line is worth is a property of the font at the display's scale rather than
//! of the layout.
//!
//! All of them draw, since none covers another. It lays out and paints, and
//! nothing more: which member a pointer fell in is `Model.resolve`'s to work out
//! from the rects it left.

const std = @import("std");

const Model = @import("../model.zig").Model;

const painter_mod = @import("../painter.zig");
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

/// `members` are listed top to bottom. Each answers `height` with what it wants,
/// or null to take a share of whatever is left over.
pub fn VTuple(comptime members: []const type) type {
    return struct {
        const Self = @This();
        pub const count = members.len;

        items: std.meta.Tuple(members),

        /// What each member was given, kept only so a test can read back where
        /// the bands landed.
        rects: [count]Rect = empty: {
            var none: [count]Rect = undefined;
            for (&none) |*rect| rect.* = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            break :empty none;
        },

        pub fn init(items: std.meta.Tuple(members)) Self {
            return .{ .items = items };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            inline for (0..count) |i| self.items[i].deinit(allocator);
        }

        /// Asks every member how tall it wants to be, hands what is left to the
        /// ones that did not say, and places them from the top.
        pub fn place(self: *Self, model: *Model, rect: Rect) !void {
            var asked: [count]?f32 = undefined;
            var spoken: f32 = 0;
            var quiet: usize = 0;
            inline for (0..count) |i| {
                asked[i] = self.items[i].height(model);
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
                try self.items[i].place(model, self.rects[i]);
                top += want;
            }
        }

        pub fn draw(self: *Self, model: *const Model, painter: *Painter) !void {
            inline for (0..count) |i| try self.items[i].draw(model, painter);
        }
    };
}

/// A member that wants `wants` pixels, or all it can get when that is null.
/// Nothing but a rect, since layout is the whole of what these tests are about.
fn Band(comptime wants: ?f32) type {
    return struct {
        const Self = @This();
        rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

        pub fn deinit(_: *Self, _: std.mem.Allocator) void {}
        pub fn draw(_: *Self, _: *const Model, _: *Painter) !void {}

        pub fn height(_: *const Self, _: *const Model) ?f32 {
            return wants;
        }

        pub fn place(self: *Self, _: *Model, rect: Rect) !void {
            self.rect = rect;
        }
    };
}

const Heading = Band(20);
const List = Band(null);
const Footer = Band(10);

fn testModel(allocator: std.mem.Allocator) Model {
    return .{ .allocator = allocator, .io = undefined };
}

test "a member that says nothing takes what is left" {
    var model = testModel(std.testing.allocator);

    var column: VTuple(&.{ Heading, List, Footer }) = .init(.{ .{}, .{}, .{} });
    try column.place(&model, .{ .x = 0, .y = 0, .width = 100, .height = 100 });

    try std.testing.expectEqual(@as(f32, 0), column.items[0].rect.y);
    try std.testing.expectEqual(@as(f32, 20), column.items[0].rect.height);
    // 100 less the 20 and the 10 that were asked for.
    try std.testing.expectEqual(@as(f32, 20), column.items[1].rect.y);
    try std.testing.expectEqual(@as(f32, 70), column.items[1].rect.height);
    try std.testing.expectEqual(@as(f32, 90), column.items[2].rect.y);
    try std.testing.expectEqual(@as(f32, 10), column.items[2].rect.height);
}

test "the bands meet exactly, whatever the fractions" {
    var model = testModel(std.testing.allocator);

    const Thirds = Band(33.4);
    var column: VTuple(&.{ Thirds, Thirds, List }) = .init(.{ .{}, .{}, .{} });
    try column.place(&model, .{ .x = 0, .y = 5, .width = 100, .height = 100 });

    // No seam and no overlap: each band starts where the one above it ended.
    for (column.rects[1..], column.rects[0 .. column.rects.len - 1]) |below, above| {
        try std.testing.expectEqual(above.y + above.height, below.y);
    }
    // And the column ends where the rect does.
    const last = column.rects[column.rects.len - 1];
    try std.testing.expectEqual(@as(f32, 105), last.y + last.height);
}

test "a column with nothing spare does not stretch anyone" {
    var model = testModel(std.testing.allocator);

    var column: VTuple(&.{ Heading, Footer }) = .init(.{ .{}, .{} });
    try column.place(&model, .{ .x = 0, .y = 0, .width = 100, .height = 500 });

    try std.testing.expectEqual(@as(f32, 20), column.items[0].rect.height);
    try std.testing.expectEqual(@as(f32, 10), column.items[1].rect.height);
}

test "asking for more than there is leaves nothing spare rather than a negative band" {
    var model = testModel(std.testing.allocator);

    var column: VTuple(&.{ Heading, List }) = .init(.{ .{}, .{} });
    try column.place(&model, .{ .x = 0, .y = 0, .width = 100, .height = 8 });

    try std.testing.expectEqual(@as(f32, 0), column.items[1].rect.height);
}

