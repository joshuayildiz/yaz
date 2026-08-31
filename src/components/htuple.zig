//! A row of components, left to right.
//!
//! The horizontal counterpart of `ZTuple`, and built the same way: the members
//! are fixed at compile time, and what varies at runtime is which of them is
//! being used. There they are stacked and one is in front; here they are side by
//! side and one has the keyboard.
//!
//! All of them draw, because none of them covers another. A press moves the
//! keyboard and takes the pointer until it is let go, so a drag that wanders out
//! of the member it began in stays with it. Only the pointer is caught that way:
//! typing goes to the focused member wherever the pointer happens to be.

const std = @import("std");

const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const Intent = event_mod.Intent;

const GlyphAtlas = @import("../glyph_atlas.zig").GlyphAtlas;
const Context = @import("../context.zig").Context;

const painter_mod = @import("../painter.zig");
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

/// `members` are listed left to right.
pub fn HTuple(comptime members: []const type) type {
    return struct {
        const Self = @This();
        pub const count = members.len;

        items: std.meta.Tuple(members),

        /// Which member a keystroke goes to. Moved by a press and by nothing
        /// else: the pointer routes by position without consulting it, so the
        /// wheel turns whatever it is over without deciding where typing lands.
        focus: usize = 0,

        /// Which member has the pointer, from a press until the release.
        holding: ?usize = null,

        /// What each member was given, so a point can be turned back into the
        /// member it fell in. Kept here because a member need not have a rect of
        /// its own to be asked about.
        rects: [count]Rect = empty: {
            var none: [count]Rect = undefined;
            for (&none) |*rect| rect.* = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            break :empty none;
        },

        pub fn init(items: std.meta.Tuple(members)) Self {
            return .{ .items = items };
        }

        pub fn deinit(self: *Self, cx: *Context) void {
            inline for (0..count) |i| self.items[i].deinit(cx);
        }

        /// Whether `T` is a member, answered at compile time so the branch it
        /// guards is compiled out of a row that has no such member.
        pub fn has(comptime T: type) bool {
            inline for (members) |member| {
                if (member == T) return true;
            }
            return false;
        }

        /// The first member of type `T`.
        pub fn get(self: *Self, comptime T: type) *T {
            return &self.items[comptime indexOf(T)];
        }

        /// The member with the keyboard, when it is a `T`, and null when the
        /// keyboard is somewhere else. What lets a caller act on the focused
        /// member without the row knowing what any of them are.
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
            @compileError(@typeName(T) ++ " is not in this row");
        }

        /// Equal columns, left to right.
        pub fn place(self: *Self, cx: *Context, rect: Rect) void {
            var left = rect.x;
            inline for (0..count) |i| {
                // Each edge from the full width rather than by adding widths up,
                // so rounding cannot leave a seam between two columns or short
                // of the last one.
                const right = @round(rect.x + rect.width * @as(f32, i + 1) / @as(f32, count));
                self.rects[i] = .{ .x = left, .y = rect.y, .width = right - left, .height = rect.height };
                self.items[i].place(cx, self.rects[i]);
                left = right;
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

        /// All of them: side by side, none covers another.
        pub fn draw(self: *Self, cx: *Context, painter: *Painter) !void {
            inline for (0..count) |i| try self.items[i].draw(cx, painter);
        }

        pub fn update(self: *Self, cx: *Context, event: Event) !Intent {
            switch (event) {
                .press => |at| {
                    const which = self.over(at) orelse return .nothing;

                    // Nothing is marked dirty for the move itself. The member
                    // pressed marks itself, and anything that draws the focus --
                    // the tab bar does -- is read back out of the members while
                    // that frame is being put together.
                    self.focus = which;
                    self.holding = which;
                    return self.tell(cx, which, event);
                },
                // Whoever took the press keeps the drag, wherever it wanders.
                // Without this a drag crossing into the next member would be
                // handed over half way through.
                .move => |at| return self.tell(cx, self.holding orelse self.over(at) orelse return .nothing, event),
                .release => {
                    const which = self.holding orelse return .nothing;
                    self.holding = null;
                    return self.tell(cx, which, event);
                },
                // The wheel turns whatever it is over, which is what one expects
                // of it, and does not decide where typing lands.
                .wheel => |wheel| return self.tell(cx, self.over(wheel.at) orelse return .nothing, event),
                // Everything left is typing, which goes to the focused member
                // wherever the pointer happens to be -- including mid-drag.
                else => return self.tell(cx, self.focus, event),
            }
        }

        /// Which member a point falls in. They do not overlap, so at most one
        /// can answer.
        fn over(self: *const Self, at: [2]f32) ?usize {
            for (self.rects, 0..) |rect, which| {
                if (rect.contains(at)) return which;
            }
            return null;
        }

        /// The members are of different types and `which` is a runtime value, so
        /// reaching one is a selection rather than an index.
        fn tell(self: *Self, cx: *Context, which: usize, event: Event) !Intent {
            inline for (0..count) |i| {
                if (which == i) return self.items[i].update(cx, event);
            }
            unreachable;
        }
    };
}

/// A member that records the room it was given and what it was told, so routing
/// can be checked without a window or a font.
fn Spy(comptime tag: u8) type {
    return struct {
        const Self = @This();
        told: *std.ArrayList(u8),
        rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

        pub fn deinit(_: *Self, _: *Context) void {}
        pub fn isDirty(_: *const Self) bool {
            return false;
        }
        pub fn setDirty(_: *Self, _: bool) void {}
        pub fn invalidate(_: *Self) void {}
        pub fn draw(_: *Self, _: *Context, _: *Painter) !void {}

        pub fn place(self: *Self, _: *Context, rect: Rect) void {
            self.rect = rect;
        }

        pub fn update(self: *Self, cx: *Context, _: Event) !Intent {
            try self.told.append(cx.allocator, tag);
            return .nothing;
        }
    };
}

const Left = Spy('l');
const Right = Spy('r');
const Row = HTuple(&.{ Left, Right });

fn testRow(cx: *Context, told: *std.ArrayList(u8)) Row {
    var row: Row = .init(.{
        .{ .told = told },
        .{ .told = told },
    });
    row.place(cx, .{ .x = 0, .y = 0, .width = 100, .height = 50 });
    return row;
}

fn testContext(allocator: std.mem.Allocator) Context {
    return .{ .allocator = allocator, .io = undefined };
}

test "the room is divided evenly, left to right" {
    const allocator = std.testing.allocator;
    var cx = testContext(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    const row = testRow(&cx, &told);
    try std.testing.expectEqual(@as(f32, 0), row.items[0].rect.x);
    try std.testing.expectEqual(@as(f32, 50), row.items[0].rect.width);
    // The second starts exactly where the first ends: no seam, no overlap.
    try std.testing.expectEqual(@as(f32, 50), row.items[1].rect.x);
    try std.testing.expectEqual(@as(f32, 50), row.items[1].rect.width);
}

test "a press moves the keyboard and typing follows it" {
    const allocator = std.testing.allocator;
    var cx = testContext(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var row = testRow(&cx, &told);
    _ = try row.update(&cx, .{ .text = "a" });
    _ = try row.update(&cx, .{ .press = .{ 75, 10 } });
    _ = try row.update(&cx, .{ .text = "b" });

    // Typed left, pressed right, typed right.
    try std.testing.expectEqualStrings("lrr", told.items);
    try std.testing.expectEqual(@as(usize, 1), row.focus);
}

test "the wheel turns what it is over without moving the keyboard" {
    const allocator = std.testing.allocator;
    var cx = testContext(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var row = testRow(&cx, &told);
    _ = try row.update(&cx, .{ .wheel = .{ .delta = 3, .at = .{ 75, 10 } } });
    _ = try row.update(&cx, .{ .text = "a" });

    try std.testing.expectEqualStrings("rl", told.items);
    try std.testing.expectEqual(@as(usize, 0), row.focus);
}

test "a drag stays with the member it began in" {
    const allocator = std.testing.allocator;
    var cx = testContext(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var row = testRow(&cx, &told);
    _ = try row.update(&cx, .{ .press = .{ 10, 10 } });
    // Wandered into the right-hand member, and out of the row entirely.
    _ = try row.update(&cx, .{ .move = .{ 75, 10 } });
    _ = try row.update(&cx, .{ .move = .{ 400, 10 } });
    // The release goes to it as well, so it can let go of whatever it took hold
    // of; only then does the next move go to whatever it is over.
    _ = try row.update(&cx, .release);
    _ = try row.update(&cx, .{ .move = .{ 75, 10 } });

    try std.testing.expectEqualStrings("llllr", told.items);
}

test "typing during a drag goes to the keyboard, not to the drag" {
    const allocator = std.testing.allocator;
    var cx = testContext(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var row = testRow(&cx, &told);
    // Focus the right-hand member, then start a drag in the left-hand one.
    _ = try row.update(&cx, .{ .press = .{ 75, 10 } });
    row.focus = 1;
    _ = try row.update(&cx, .{ .press = .{ 10, 10 } });
    row.focus = 1;
    told.clearRetainingCapacity();

    _ = try row.update(&cx, .{ .move = .{ 10, 20 } });
    _ = try row.update(&cx, .{ .text = "a" });

    // The move went to the drag, the character to the keyboard.
    try std.testing.expectEqualStrings("lr", told.items);
}

test "a point outside every member is nobody's" {
    const allocator = std.testing.allocator;
    var cx = testContext(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    var row = testRow(&cx, &told);
    _ = try row.update(&cx, .{ .press = .{ 400, 10 } });
    _ = try row.update(&cx, .{ .wheel = .{ .delta = 3, .at = .{ 400, 10 } } });
    try std.testing.expectEqualStrings("", told.items);
}
