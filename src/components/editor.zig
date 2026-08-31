//! The editing window: the files, and the finder over them.
//!
//! Which of the two is in front is not this to remember. `model.finding` is
//! null or it is not, and that is the whole of what "the panel is open" means:
//! a keystroke goes to the panel while there is one and to the files while
//! there is not, and the panel draws last because it lies over them.
//!
//! The files are still drawn underneath it. The panel is two small opaque
//! surfaces, not a page that replaced one, and the code either side of them is
//! at full contrast.

const Model = @import("../model.zig").Model;

const message_mod = @import("../message.zig");
const Message = message_mod.Message;
const Effect = message_mod.Effect;

const painter_mod = @import("../painter.zig");
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const Finder = @import("./finder.zig").Finder;
const Workbench = @import("./workbench.zig").Workbench;

pub const Editor = struct {
    workbench: Workbench = .{},
    finder: Finder = .{},

    pub fn deinit(self: *Editor, model: *Model) void {
        self.workbench.deinit(model);
        self.finder.deinit(model);
    }

    /// Both get the whole window. The workbench divides it; the finder lies
    /// over it and wants all of it to measure from.
    pub fn place(self: *Editor, model: *const Model, rect: Rect) void {
        self.workbench.place(model, rect);
        self.finder.place(model, rect);
    }

    pub fn invalidate(self: *Editor) void {
        self.workbench.invalidate();
        self.finder.invalidate();
    }

    pub fn draw(self: *Editor, model: *const Model, painter: *Painter) !void {
        try self.workbench.draw(model, painter);
        try self.finder.draw(model, painter);
    }

    /// The panel while there is one, the files otherwise -- and cmd+P, which
    /// belongs to neither: it is the keystroke that decides which of them there
    /// is. Pressed while the panel is up it reaches the panel, which asks to be
    /// put away, exactly as escape does.
    pub fn update(self: *Editor, model: *const Model, message: Message) !Effect {
        if (model.finding != null) return self.finder.update(model, message);

        switch (message) {
            .find => return .find,
            else => return self.workbench.update(model, message),
        }
    }
};
