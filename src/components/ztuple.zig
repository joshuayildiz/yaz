//! A stack of components, back to front.
//!
//! Everything in it draws, bottom first, so what is behind is still there --
//! the finder is two small surfaces over a file, not a page that replaced
//! one, and the code either side of them is not dimmed. Only the component in
//! front is told what happened, which is what being in front means.
//!
//! The members are fixed at compile time and their order is not, and the stack
//! is what changes it: the keystroke that shows a panel reaches the panel
//! wherever it is, and a panel that has finished says so and goes back. There
//! is no separate notion of a thing being open, and nothing above has to know
//! which member is a panel.
//!
//! Static composition, so the calls below inline to the members' own: a stack is
//! a tuple and a permutation of it, not a list of pointers to dispatch through.

const std = @import("std");

const message_mod = @import("../message.zig");
const Message = message_mod.Message;
const Intent = message_mod.Intent;

const GlyphAtlas = @import("../glyph_atlas.zig").GlyphAtlas;
const Model = @import("../model.zig").Model;

const painter_mod = @import("../painter.zig");
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

/// `members` are listed back to front, which is also the order they start in.
pub fn ZTuple(comptime members: []const type) type {
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

        pub fn deinit(self: *Self, model: *Model) void {
            inline for (0..count) |i| self.items[i].deinit(model);
        }

        pub fn get(self: *Self, comptime T: type) *T {
            return &self.items[comptime indexOf(T)];
        }

        /// Whether `T` is the one being told what happens.
        pub fn inFront(self: *const Self, comptime T: type) bool {
            return self.order[count - 1] == comptime indexOf(T);
        }

        /// Brings `T` to the front. What was above it moves back one.
        pub fn raise(self: *Self, model: *Model, comptime T: type) void {
            self.raiseAt(model, comptime indexOf(T));
        }

        fn raiseAt(self: *Self, model: *Model, which: usize) void {
            const at = std.mem.indexOfScalar(usize, &self.order, which).?;
            std.mem.copyForwards(usize, self.order[at..], self.order[at + 1 ..]);
            self.order[count - 1] = which;
            model.changed();
        }

        /// Sends whatever is in front all the way back, which is where a panel
        /// goes when it is done. A stack of one has no front to give up.
        pub fn lowerFront(self: *Self, model: *Model) void {
            const front = self.order[count - 1];
            std.mem.copyBackwards(usize, self.order[1..], self.order[0 .. count - 1]);
            self.order[0] = front;
            model.changed();
        }

        fn indexOf(comptime T: type) usize {
            inline for (members, 0..) |member, i| {
                if (member == T) return i;
            }
            @compileError(@typeName(T) ++ " is not in this stack");
        }

        pub fn place(self: *Self, model: *Model, rect: Rect) void {
            inline for (0..count) |i| self.items[i].place(model, rect);
        }

        pub fn invalidate(self: *Self) void {
            inline for (0..count) |i| self.items[i].invalidate();
        }

        /// Back to front. The order is a runtime value and the members are of
        /// different types, so the loop over it selects rather than indexes.
        pub fn draw(self: *Self, model: *Model, painter: *Painter) !void {
            for (self.order) |which| {
                inline for (0..count) |i| {
                    if (which == i) try self.items[i].draw(model, painter);
                }
            }
        }

        /// The one in front, and only it. What is behind is being looked at, not
        /// used, so a click through a panel cannot reach what it is covering.
        ///
        /// `find` is the exception, and it is an exception about the order
        /// rather than about a member: a panel is a member that can be shown,
        /// and the keystroke that shows one is a fact about the window, so it
        /// reaches the panel from anywhere in the order. Pressed while the
        /// panel is already in front it falls through to the panel itself,
        /// which asks to be put away exactly as escape makes it.
        pub fn update(self: *Self, model: *Model, message: Message) !Intent {
            switch (message) {
                .find => inline for (0..count) |i| {
                    if (comptime @hasDecl(members[i], "show")) {
                        if (self.order[count - 1] != i) {
                            try self.items[i].show(model);
                            self.raiseAt(model, i);
                            return .nothing;
                        }
                    }
                },
                else => {},
            }

            const front = self.order[count - 1];
            var asked: Intent = .nothing;
            inline for (0..count) |i| {
                if (front == i) asked = try self.items[i].update(model, message);
            }
            return self.pass(model, asked);
        }

        /// What the front asked for, offered to the ones behind it in turn
        /// until one takes it.
        ///
        /// This is how a panel reaches what it is covering without either of
        /// them knowing the other exists: the finder knows a file was picked
        /// and nothing else, and the thing behind it knows what to do with a
        /// file and nothing about panels. One that takes it and wants the panel
        /// gone answers `dismiss`, which is the same word the panel uses to ask
        /// for itself.
        ///
        /// What comes back is what nobody took, and whatever it carries is
        /// still the caller's to free.
        fn pass(self: *Self, model: *Model, asked: Intent) !Intent {
            var intent = asked;
            var behind = count - 1;
            while (behind > 0) : (behind -= 1) {
                switch (intent) {
                    .nothing => return .nothing,
                    .dismiss => {
                        self.lowerFront(model);
                        return .nothing;
                    },
                    else => {},
                }

                const which = self.order[behind - 1];
                inline for (0..count) |i| {
                    if (comptime @hasDecl(members[i], "offer")) {
                        if (which == i) intent = try self.items[i].offer(model, intent);
                    }
                }
            }

            switch (intent) {
                .nothing => return .nothing,
                .dismiss => {
                    self.lowerFront(model);
                    return .nothing;
                },
                else => return intent,
            }
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

        pub fn deinit(_: *Self, _: *Model) void {}
        pub fn place(_: *Self, _: *Model, _: Rect) void {}
        pub fn invalidate(_: *Self) void {}

        pub fn draw(self: *Self, model: *Model, _: *Painter) !void {
            try self.drawn.append(model.allocator, tag);
        }

        pub fn update(self: *Self, model: *Model, _: Message) !Intent {
            try self.told.append(model.allocator, tag);
            return .nothing;
        }
    };
}

/// A panel: it can be shown, and it asks for what it cannot do itself.
const Panel = struct {
    shown: usize = 0,
    asks: Intent = .nothing,

    pub fn deinit(_: *Panel, _: *Model) void {}
    pub fn place(_: *Panel, _: *Model, _: Rect) void {}
    pub fn draw(_: *Panel, _: *Model, _: *Painter) !void {}
    pub fn invalidate(_: *Panel) void {}

    pub fn show(self: *Panel, _: *Model) !void {
        self.shown += 1;
    }

    pub fn update(self: *Panel, _: *Model, _: Message) !Intent {
        return self.asks;
    }
};

/// What sits behind one: it takes a path and wants the panel gone afterwards.
const Taker = struct {
    took: ?[]u8 = null,

    pub fn deinit(_: *Taker, _: *Model) void {}
    pub fn place(_: *Taker, _: *Model, _: Rect) void {}
    pub fn draw(_: *Taker, _: *Model, _: *Painter) !void {}
    pub fn invalidate(_: *Taker) void {}

    pub fn update(_: *Taker, _: *Model, _: Message) !Intent {
        return .nothing;
    }

    pub fn offer(self: *Taker, _: *Model, intent: Intent) !Intent {
        switch (intent) {
            .open => |path| {
                self.took = path;
                return .dismiss;
            },
            else => return intent,
        }
    }
};

fn testModel(allocator: std.mem.Allocator) Model {
    return .{ .allocator = allocator, .io = undefined };
}

test "everything draws back to front, and only the front is told" {
    const allocator = std.testing.allocator;
    var model = testModel(allocator);
    var drawn: std.ArrayList(u8) = .empty;
    defer drawn.deinit(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    const Back = Spy('b');
    const Front = Spy('f');
    var stack: ZTuple(&.{ Back, Front }) = .init(.{
        .{ .drawn = &drawn, .told = &told },
        .{ .drawn = &drawn, .told = &told },
    });

    // Declared back to front, so the last one starts in front.
    try stack.draw(&model, undefined);
    _ = try stack.update(&model, .cancel);
    try std.testing.expectEqualStrings("bf", drawn.items);
    try std.testing.expectEqualStrings("f", told.items);

    // Raising the back one turns the drawing order round and moves the keyboard
    // with it.
    stack.raise(&model, Back);
    try stack.draw(&model, undefined);
    _ = try stack.update(&model, .cancel);
    try std.testing.expectEqualStrings("bffb", drawn.items);
    try std.testing.expectEqualStrings("fb", told.items);

    // And putting it away returns both to where they were.
    stack.lowerFront(&model);
    try stack.draw(&model, undefined);
    _ = try stack.update(&model, .cancel);
    try std.testing.expectEqualStrings("bffbbf", drawn.items);
    try std.testing.expectEqualStrings("fbf", told.items);
}

test "a change of order is a change to what is on screen" {
    const allocator = std.testing.allocator;
    var model = testModel(allocator);
    const Back = Spy('b');
    const Front = Spy('f');
    var stack: ZTuple(&.{ Back, Front }) = .init(.{
        .{ .drawn = undefined, .told = undefined },
        .{ .drawn = undefined, .told = undefined },
    });

    // Nothing inside a member moved, so the order is the only thing that can
    // have asked for a frame.
    model.dirty = false;
    stack.raise(&model, Back);
    try std.testing.expect(model.dirty);

    model.dirty = false;
    stack.lowerFront(&model);
    try std.testing.expect(model.dirty);
}

test "the keystroke that shows a panel finds it wherever it is" {
    const allocator = std.testing.allocator;
    var model = testModel(allocator);
    var stack: ZTuple(&.{ Taker, Panel }) = .init(.{ .{}, .{} });

    // In front to begin with, so cmd+P is the panel's own to answer -- which is
    // what makes pressing it again close the panel rather than reopen it.
    _ = try stack.update(&model, .find);
    try std.testing.expectEqual(@as(usize, 0), stack.get(Panel).shown);

    stack.lowerFront(&model);
    _ = try stack.update(&model, .find);
    try std.testing.expectEqual(@as(usize, 1), stack.get(Panel).shown);
    try std.testing.expect(stack.inFront(Panel));
}

test "what the front asks for is offered to what is behind it" {
    const allocator = std.testing.allocator;
    var model = testModel(allocator);
    var stack: ZTuple(&.{ Taker, Panel }) = .init(.{ .{}, .{} });

    const path = try allocator.dupe(u8, "src/main.zig");
    defer allocator.free(path);
    stack.get(Panel).asks = .{ .open = path };

    const left = try stack.update(&model, .newline);

    // Taken, so nothing comes back out -- and taking it put the panel away,
    // which is the whole of what opening a file from one looks like.
    try std.testing.expectEqual(Intent.nothing, left);
    try std.testing.expectEqualStrings("src/main.zig", stack.get(Taker).took.?);
    try std.testing.expect(stack.inFront(Taker));
}

test "what nobody takes comes back out" {
    const allocator = std.testing.allocator;
    var model = testModel(allocator);
    var stack: ZTuple(&.{ Panel, Panel }) = .init(.{ .{}, .{} });

    const path = try allocator.dupe(u8, "src/main.zig");
    defer allocator.free(path);
    stack.items[1].asks = .{ .open = path };

    // Nothing behind it can take a path, so it is still the caller's to free.
    const left = try stack.update(&model, .newline);
    try std.testing.expectEqualStrings("src/main.zig", left.open);
}

test "a stack of one has no front to give up" {
    const allocator = std.testing.allocator;
    var model = testModel(allocator);
    var drawn: std.ArrayList(u8) = .empty;
    defer drawn.deinit(allocator);
    var told: std.ArrayList(u8) = .empty;
    defer told.deinit(allocator);

    const Only = Spy('o');
    var stack: ZTuple(&.{Only}) = .init(.{.{ .drawn = &drawn, .told = &told }});

    stack.lowerFront(&model);
    stack.raise(&model, Only);
    try stack.draw(&model, undefined);
    try std.testing.expectEqualStrings("o", drawn.items);
    try std.testing.expect(stack.inFront(Only));
}
