//! The editing window: the files, the sidebar tree beside them, and the finder
//! over both. It places the three and draws them; where a message goes is the
//! model's, resolved against the layout left here.
//!
//! Which of the finder or the files has the keyboard is `model.finding` -- null
//! or not is the whole of what "the panel is open" means -- and the panel draws
//! last because it lies over the files, at full contrast either side of it.
//!
//! The tree is not a panel: `model.sidebar.open` says whether it is there, and
//! when it is it takes a strip off the left rather than lying over anything, so
//! the files get what is left.

const std = @import("std");

const Model = @import("../model.zig").Model;

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
    workbench: Workbench = .init(.{ .{}, .{} }),
    tree: Tree = .{},
    finder: Finder = .{},

    pub fn deinit(self: *Editor, allocator: std.mem.Allocator) void {
        self.workbench.deinit(allocator);
        self.tree.deinit(allocator);
        self.finder.deinit(allocator);
    }

    /// The tree takes a strip off the left when it is open and the workbench
    /// takes the rest; when it is closed the workbench takes it all. The finder
    /// lies over everything and wants the whole window to measure from. Where
    /// the strip landed is `tree.place`'s to record, on `model.sidebar`, which
    /// is where a press is tested against it.
    pub fn place(self: *Editor, model: *Model, rect: Rect) !void {
        if (model.sidebar.open) {
            const width = @min(@round(sidebar_width * model.atlas.scale), @round(rect.width / 2));
            try self.tree.place(model, .{ .x = rect.x, .y = rect.y, .width = width, .height = rect.height });
            try self.workbench.place(model, .{
                .x = rect.x + width,
                .y = rect.y,
                .width = rect.width - width,
                .height = rect.height,
            });
        } else {
            try self.workbench.place(model, rect);
        }

        try self.finder.place(model, rect);
    }

    pub fn draw(self: *Editor, model: *const Model, painter: *Painter) !void {
        try self.workbench.draw(model, painter);
        if (model.sidebar.open) try self.tree.draw(model, painter);
        try self.finder.draw(model, painter);
    }

};
