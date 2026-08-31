//! A stack of components, back to front.
//!
//! Everything in it draws, bottom first, so what is behind shows through what is
//! over it -- the finder's scrim is a sheet of near-white laid on a document,
//! not a page that replaced one. Only the component in front is told what
//! happened, which is what being in front means.
//!
//! The members are fixed at compile time and their order is not. `raise` and
//! `lowerFront` move one, and that is the whole of showing a panel and putting
//! it away; there is no separate notion of a thing being open.
//!
//! Static composition, so the calls below inline to the members' own: a stack is
//! a tuple and a permutation of it, not a list of pointers to dispatch through.

const std = @import("std");

const event_mod = @import("../event.zig");
const Event = event_mod.Event;
const Intent = event_mod.Intent;

const GlyphAtlas = @import("../glyph_atlas.zig").GlyphAtlas;

const painter_mod = @import("../painter.zig");
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

/// `members` are listed back to front, which is also the order they start in.
pub fn ZStack(comptime members: []const type) type {
    return struct {
        const Self = @This();
        const count = members.len;

        items: std.meta.Tuple(members),

        /// Indices into `items`, back to front.
        order: [count]usize = declared: {
            var initial: [count]usize = undefined;
            for (&initial, 0..) |*slot, i| slot.* = i;
            break :declared initial;
        },

        pub fn init(items: std.meta.Tuple(members)) Self {
            return .{ .items = items };
        }

        pub fn deinit(self: *Self) void {
            inline for (0..count) |i| self.items[i].deinit();
        }

        /// Whether `T` is a member. A question about the stack rather than about
        /// this one of them, so it is answered at compile time and the branch it
        /// guards is compiled out of a stack that has no such member.
        pub fn has(comptime T: type) bool {
            inline for (members) |member| {
                if (member == T) return true;
            }
            return false;
        }

        pub fn get(self: *Self, comptime T: type) *T {
            return &self.items[comptime indexOf(T)];
        }

        /// Whether `T` is the one being told what happens.
        pub fn inFront(self: *const Self, comptime T: type) bool {
            return self.order[count - 1] == comptime indexOf(T);
        }

        /// Brings `T` to the front. What was above it moves back one.
        pub fn raise(self: *Self, comptime T: type) void {
            const which = comptime indexOf(T);
            const at = std.mem.indexOfScalar(usize, &self.order, which).?;
            std.mem.copyForwards(usize, self.order[at..], self.order[at + 1 ..]);
            self.order[count - 1] = which;
        }

        /// Sends whatever is in front all the way back, which is where a panel
        /// goes when it is done. A stack of one has no front to give up.
        pub fn lowerFront(self: *Self) void {
            const front = self.order[count - 1];
            std.mem.copyBackwards(usize, self.order[1..], self.order[0 .. count - 1]);
            self.order[0] = front;
        }

        fn indexOf(comptime T: type) usize {
            inline for (members, 0..) |member, i| {
                if (member == T) return i;
            }
            @compileError(@typeName(T) ++ " is not in this stack");
        }

        pub fn place(self: *Self, rect: Rect, atlas: *const GlyphAtlas) void {
            inline for (0..count) |i| self.items[i].place(rect, atlas);
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

        /// Back to front. The order is a runtime value and the members are of
        /// different types, so the loop over it selects rather than indexes.
        pub fn draw(self: *Self, atlas: *GlyphAtlas, painter: *Painter) !void {
            for (self.order) |which| {
                inline for (0..count) |i| {
                    if (which == i) try self.items[i].draw(atlas, painter);
                }
            }
        }

        /// The one in front, and only it. What is behind is being looked at, not
        /// used, so a click through a panel cannot reach what it is covering.
        pub fn update(self: *Self, event: Event, atlas: *GlyphAtlas) !Intent {
            const front = self.order[count - 1];
            inline for (0..count) |i| {
                if (front == i) return self.items[i].update(event, atlas);
            }
            unreachable;
        }
    };
}

/// Two components that record what they were told, so the order can be checked
/// without a window or a font.
fn Spy(comptime tag: u8) type {
    return struct {
        const Self = @This();
        drawn: *std.ArrayList(u8),
        told: *std.ArrayList(u8),
        gpa: std.mem.Allocator,

        pub fn deinit(_: *Self) void {}
        pub fn place(_: *Self, _: Rect, _: *const GlyphAtlas) void {}
        pub fn isDirty(_: *const Self) bool {
            return false;
        }
        pub fn setDirty(_: *Self, _: bool) void {}
        pub fn invalidate(_: *Self) void {}

        pub fn draw(self: *Self, _: *GlyphAtlas, _: *Painter) !void {
            try self.drawn.append(self.gpa, tag);
        }

        pub fn update(self: *Self, _: Event, _: *GlyphAtlas) !Intent {
            try self.told.append(self.gpa, tag);
            return .nothing;
        }
    };
}

test "everything draws back to front, and only the front is told" {
    const gpa = std.testing.allocator;
    var drawn: std.ArrayList(u8) = .empty;
    defer drawn.deinit(gpa);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(gpa);

    const Back = Spy('b');
    const Front = Spy('f');
    var stack: ZStack(&.{ Back, Front }) = .init(.{
        .{ .drawn = &drawn, .told = &told, .gpa = gpa },
        .{ .drawn = &drawn, .told = &told, .gpa = gpa },
    });

    // Declared back to front, so the last one starts in front.
    try stack.draw(undefined, undefined);
    _ = try stack.update(.cancel, undefined);
    try std.testing.expectEqualStrings("bf", drawn.items);
    try std.testing.expectEqualStrings("f", told.items);

    // Raising the back one turns the drawing order round and moves the keyboard
    // with it.
    stack.raise(Back);
    try stack.draw(undefined, undefined);
    _ = try stack.update(.cancel, undefined);
    try std.testing.expectEqualStrings("bffb", drawn.items);
    try std.testing.expectEqualStrings("fb", told.items);

    // And putting it away returns both to where they were.
    stack.lowerFront();
    try stack.draw(undefined, undefined);
    _ = try stack.update(.cancel, undefined);
    try std.testing.expectEqualStrings("bffbbf", drawn.items);
    try std.testing.expectEqualStrings("fbf", told.items);
}

test "a stack knows its members at compile time" {
    const Back = Spy('b');
    const Front = Spy('f');
    const Absent = Spy('x');
    const Stack = ZStack(&.{ Back, Front });

    try std.testing.expect(Stack.has(Back));
    try std.testing.expect(Stack.has(Front));
    try std.testing.expect(!Stack.has(Absent));
}

test "a stack of one has no front to give up" {
    const gpa = std.testing.allocator;
    var drawn: std.ArrayList(u8) = .empty;
    defer drawn.deinit(gpa);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(gpa);

    const Only = Spy('o');
    var stack: ZStack(&.{Only}) = .init(.{.{ .drawn = &drawn, .told = &told, .gpa = gpa }});

    stack.lowerFront();
    stack.raise(Only);
    try stack.draw(undefined, undefined);
    try std.testing.expectEqualStrings("o", drawn.items);
    try std.testing.expect(stack.inFront(Only));
}
