//! The editing window: the files, the sidebar tree beside them, and the finder
//! over both.
//!
//! Which of the finder or the files has the keyboard is not this to remember.
//! `model.finding` is null or it is not, and that is the whole of what "the
//! panel is open" means: a keystroke goes to the panel while there is one and to
//! the files while there is not, and the panel draws last because it lies over
//! them.
//!
//! The tree is not a panel. `model.sidebar.open` says whether it is there, and
//! when it is it takes a strip off the left rather than lying over anything: the
//! files get what is left, and a press is handed to whichever of the two it
//! landed in.

const std = @import("std");

const Model = @import("../model.zig").Model;

const message_mod = @import("../message.zig");
const Message = message_mod.Message;
const Change = message_mod.Change;

const painter_mod = @import("../painter.zig");
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const Finder = @import("./finder.zig").Finder;
const Tree = @import("./tree.zig").Tree;
const Workbench = @import("./workbench.zig").Workbench;

/// How wide the sidebar is, in points scaled like the font. Never more than half
/// the window, so a narrow one still leaves the files somewhere to be.
const sidebar_width = 240;

pub const Editor = struct {
    workbench: Workbench = .{},
    tree: Tree = .{},
    finder: Finder = .{},

    /// Where the sidebar sits when it is open, kept so a press can be turned
    /// back into it. Zero-width when it is closed, which no press falls in.
    sidebar: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(self: *Editor, allocator: std.mem.Allocator) void {
        self.workbench.deinit(allocator);
        self.tree.deinit(allocator);
        self.finder.deinit(allocator);
    }

    /// The tree takes a strip off the left when it is open and the workbench
    /// takes the rest; when it is closed the workbench takes it all. The finder
    /// lies over everything and wants the whole window to measure from.
    pub fn place(self: *Editor, model: *const Model, rect: Rect) void {
        if (model.sidebar.open) {
            const width = @min(@round(sidebar_width * model.atlas.scale), @round(rect.width / 2));
            self.sidebar = .{ .x = rect.x, .y = rect.y, .width = width, .height = rect.height };
            self.tree.place(model, self.sidebar);
            self.workbench.place(model, .{
                .x = rect.x + width,
                .y = rect.y,
                .width = rect.width - width,
                .height = rect.height,
            });
        } else {
            self.sidebar = .{ .x = rect.x, .y = rect.y, .width = 0, .height = rect.height };
            self.workbench.place(model, rect);
        }

        self.finder.place(model, rect);
    }

    pub fn draw(self: *Editor, model: *const Model, painter: *Painter) !void {
        try self.workbench.draw(model, painter);
        if (model.sidebar.open) try self.tree.draw(model, painter);
        try self.finder.draw(model, painter);
    }

    /// The finder while it is up, the tree for a press that lands in it, and the
    /// files for everything else. cmd+P and cmd+B belong to none of them: they
    /// are what decides whether a panel is there at all. A change on disk is the
    /// tree's whether the finder is up or not, since the tree is drawn under it.
    pub fn update(self: *Editor, model: *const Model, message: Message) !Change {
        if (message == .disk_changed) return .refresh_tree;

        if (model.finding != null) return self.finder.update(model, message);

        switch (message) {
            .find => return .find,
            .toggle_tree => return .toggle_tree,
            .press => |what| {
                if (model.sidebar.open and self.sidebar.contains(what.at))
                    return self.tree.update(model, message);
                return self.workbench.update(model, message);
            },
            .look => |at| {
                // The tree has nothing to look up, so a look in it does nothing;
                // one over the files is the workbench's to route to a column.
                if (model.sidebar.open and self.sidebar.contains(at))
                    return self.tree.update(model, message);
                return self.workbench.update(model, message);
            },
            .wheel => |wheel| {
                if (model.sidebar.open and self.sidebar.contains(wheel.at))
                    return self.tree.update(model, message);
                return self.workbench.update(model, message);
            },
            else => return self.workbench.update(model, message),
        }
    }
};
