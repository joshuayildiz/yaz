const std = @import("std");

const config = @import("./config.zig");
const Renderer = @import("./renderer.zig").Renderer;
const displayScale = @import("./renderer.zig").displayScale;
const Model = @import("./model.zig").Model;
const message_mod = @import("./message.zig");
const Message = message_mod.Message;
const Effect = message_mod.Effect;
const Painter = @import("./painter.zig").Painter;
const sdl = @import("./sdl.zig");
const tools = @import("./tools.zig");
const Healthcheck = @import("./components/healthcheck.zig").Healthcheck;
const Editor = @import("./components/editor.zig").Editor;
const c = sdl.c;

/// `setup` prints, so it has to be heard from in a release build too, where the
/// default would keep everything below an error to itself.
pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    if (try wantsSetup(init)) return setup(init);

    var model: Model = .init(init);
    defer model.deinit();

    model.locate(init.minimal.environ) catch |err| switch (err) {
        error.CannotOpenLibrary, error.MissingSymbol, error.CannotIndex => {
            const stopped = try Healthcheck.init(model.allocator, init.minimal.environ, .{ .fff = true });
            return run(&model, Healthcheck, stopped);
        },
        else => |other| return other,
    };

    var named = try std.process.Args.Iterator.initAllocator(init.minimal.args, model.allocator);
    defer named.deinit();
    _ = named.skip(); // The program itself.

    while (named.next()) |path| _ = try model.open(path);

    if (model.files.items.len == 0) _ = try model.blank();

    // A column per file named, left to right in the order they were named.
    try model.columns.appendSlice(model.allocator, model.files.items);

    return run(&model, Editor, .{});
}

/// The window and the one component in it, generic over which, so a window that
/// is one thing costs no more than one thing.
fn App(comptime Component: type) type {
    return struct {
        const Self = @This();

        model: *Model,
        renderer: Renderer,
        painter: Painter,
        component: Component,

        fn deinit(self: *Self) void {
            self.component.deinit(self.model.allocator);
            self.painter.deinit();
            self.renderer.deinit();
        }

        /// The model comes back from `update` rather than being written through,
        /// so this is the one place it is put down again.
        fn update(self: *Self, message: Message) !void {
            const next, const effect = try self.model.update(message);
            self.model.* = next;

            if (effect) |asked| try self.perform(asked);
        }

        /// What the model asked for and could not do itself; whatever performing
        /// one produces loops back as a message. Keeping it out here is what lets
        /// `Model.update` be tested without SDL or a filesystem.
        ///
        /// `anyerror` because this and `update` call each other, and two inferred
        /// error sets that depend on each other cannot be worked out.
        fn perform(self: *Self, effect: Effect) anyerror!void {
            switch (effect) {
                // Reported, not returned: a clipboard or a write that fails is
                // something to be told about, not to take the window down over.
                .copy => |which| self.model.copyOut(which) catch |err| {
                    std.log.err("copy: {s}", .{@errorName(err)});
                },

                .paste => |which| {
                    const text = self.model.clipboard() catch |err| {
                        std.log.err("paste: {s}", .{@errorName(err)});
                        return;
                    } orelse return;
                    defer self.model.allocator.free(text);
                    try self.update(.{ .insert = .{ .column = which, .text = text } });
                },

                .save => |which| {
                    const file = self.model.column(which) orelse return;
                    self.model.writeOut(file) catch |err| {
                        std.log.err("{s}: {s}", .{ file.path.?, @errorName(err) });
                        return;
                    };
                    try self.update(.{ .saved = which });
                },

                // Asynchronous: the answer arrives as an event.
                .ask_name => sdl.askWhereToSave(self.renderer.window),

                // Out here rather than in the model because starting the watch
                // registers a callback that pushes an SDL event.
                .watch => self.model.watchTree(),
                .unwatch => self.model.unwatchTree(),
            }
        }

        fn redraw(self: *Self) !void {
            // Read each frame rather than listened for: several window events can
            // imply the scale changed, and a drag to another display happens
            // inside the modal loop where only the resize watch runs.
            const scale = displayScale(self.renderer.window);
            try self.renderer.atlas.setScale(scale);

            const theme = sdl.systemTheme();
            if (theme != self.renderer.theme) {
                self.renderer.theme = theme;
                sdl.setLayerBackground(self.renderer.window, config.rgba(theme, .background));
            }

            // The window, not the swapchain: the two can disagree for a frame
            // mid-resize, which is one line too many or too few.
            var width: c_int = 0;
            var height: c_int = 0;
            _ = c.SDL_GetWindowSizeInPixels(self.renderer.window, &width, &height);

            try self.component.place(self.model, .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(width),
                .height = @floatFromInt(height),
            });

            self.painter.clear();
            try self.component.draw(self.model, &self.painter);
            try self.renderer.present(&self.painter);

            // After the frame: a look worked out where its match landed while
            // placing the columns, and the pointer is moved there now it shows.
            self.warpPending();
        }

        /// Moves the pointer to where a look asked. Back in window coordinates:
        /// the request is in pixels, and SDL still speaks to the cursor in points.
        fn warpPending(self: *Self) void {
            const density = c.SDL_GetWindowPixelDensity(self.renderer.window);
            if (density <= 0) return;
            for (self.model.columns.items) |file| {
                const target = file.warp_to orelse continue;
                file.warp_to = null;
                c.SDL_WarpMouseInWindow(self.renderer.window, target[0] / density, target[1] / density);
            }
        }

        /// Windows and macOS run a modal loop while a window is dragged or
        /// resized, and do not hand control back until it ends, so
        /// `SDL_WaitEvent` is stuck inside it and nothing redraws. SDL runs a
        /// watch callback as events are pushed, which happens from within that
        /// loop.
        fn redrawWhileResizing(userdata: ?*anyopaque, event: [*c]c.SDL_Event) callconv(.c) bool {
            if (event.*.type == c.SDL_EVENT_WINDOW_EXPOSED) {
                const app: *Self = @ptrCast(@alignCast(userdata.?));
                // Swallowed: the main loop redraws and surfaces the failure once
                // it gets control back.
                app.redraw() catch {};
            }
            // A watch callback's return value is ignored.
            return true;
        }
    };
}

/// Puts a window up and runs `component` in it until it is closed.
fn run(model: *Model, comptime Component: type, component: Component) !void {
    // macOS inertial scroll is off unless asked; before `SDL_Init`, when SDL
    // reads the hint.
    _ = c.SDL_SetHint(c.SDL_HINT_MAC_SCROLL_MOMENTUM, "1");

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.err("SDL_Init: {s}", .{sdl.lastError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    // Before `SDL_Quit`, so the watcher's thread still has an event queue to push
    // into as it stops. A no-op when the tree was never opened.
    defer model.unwatchTree();

    // After `SDL_Init`, which builds the menu bar this takes it off.
    sdl.unbindCloseShortcut();

    // The event type a save dialog answers on, claimed from SDL's pool. Without
    // one a file with no name could ask and never learn the answer.
    if (!sdl.registerEvents()) {
        std.log.err("SDL_RegisterEvents: {s}", .{sdl.lastError()});
        return error.SdlRegisterEvents;
    }

    // Without `HIGH_PIXEL_DENSITY` the back buffer is window-sized and scaled up
    // to the display, which no care in the text pipeline survives.
    const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    const window = c.SDL_CreateWindow("yaz", 1024, 768, flags) orelse {
        std.log.err("SDL_CreateWindow: {s}", .{sdl.lastError()});
        return error.SdlCreateWindow;
    };
    defer c.SDL_DestroyWindow(window);

    std.log.info("video driver: {s}", .{std.mem.span(c.SDL_GetCurrentVideoDriver())});

    // So text arrives as finished characters: the input method has already
    // turned a dead key, a compose sequence or a CJK conversion into one.
    if (!c.SDL_StartTextInput(window)) {
        std.log.err("SDL_StartTextInput: {s}", .{sdl.lastError()});
        return error.SdlStartTextInput;
    }
    defer _ = c.SDL_StopTextInput(window);

    var app: App(Component) = .{
        .model = model,
        .renderer = try Renderer.init(model.allocator, window),
        .painter = .init(model.allocator),
        .component = component,
    };
    defer app.deinit();

    // The renderer owns the atlas and needs a window, so this is the first point
    // the model can have one.
    model.attach(&app.renderer.atlas);

    if (!c.SDL_AddEventWatch(App(Component).redrawWhileResizing, &app)) {
        std.log.err("SDL_AddEventWatch: {s}", .{sdl.lastError()});
        return error.SdlAddEventWatch;
    }
    defer c.SDL_RemoveEventWatch(App(Component).redrawWhileResizing, &app);

    // Blocking wait, not a poll loop: idle costs nothing. Waking up is not a
    // reason to draw, though; only a change to what is on screen is.
    var event: c.SDL_Event = undefined;
    while (model.running) {
        if (model.dirty) {
            try app.redraw();
            model.dirty = false;
        }

        if (!c.SDL_WaitEvent(&event)) {
            std.log.err("SDL_WaitEvent: {s}", .{sdl.lastError()});
            return error.SdlWaitEvent;
        }

        // Folding a whole queued burst into one redraw: presenting blocks on the
        // swapchain, so a keystroke queued behind redundant presents is latency,
        // not just work.
        while (true) {
            const density = c.SDL_GetWindowPixelDensity(window);
            const line_height = app.renderer.atlas.line_height;

            // The event carries a borrowed path that the poll below would
            // overwrite, so it is let go of here, in a block of its own.
            {
                defer sdl.releasePath(&event);
                const what = Message.init(&event, density, line_height);
                if (what != .none) try app.update(what);
            }

            if (!c.SDL_PollEvent(&event)) break;
        }
    }
}

/// `yaz setup`, and exactly that. A file genuinely named `setup` is still
/// openable, by naming it `./setup`.
fn wantsSetup(init: std.process.Init) !bool {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.skip(); // The program itself.
    const first = args.next() orelse return false;
    if (!std.mem.eql(u8, first, "setup")) return false;
    return args.next() == null;
}

/// Installs the two tools the editor will not run without.
///
/// A command rather than something startup does on its own: this is the only
/// place in yaz that reaches the network, and it should happen because it was
/// asked for.
fn setup(init: std.process.Init) !void {
    var failed = false;

    for (tools.Tool.all) |tool| {
        const exe = try tools.path(init.gpa, init.minimal.environ, tool);
        defer init.gpa.free(exe);

        if (tools.probe(exe)) {
            std.log.info("{s} is already installed at {s}", .{ tool.title(), exe });
            continue;
        }

        std.log.info("installing {s}", .{tool.title()});
        tools.install(init.gpa, init.io, init.minimal.environ, tool) catch |err| {
            std.log.err("{s}: {s}", .{ tool.title(), @errorName(err) });
            failed = true;
            continue;
        };

        // What was written, not what was downloaded: the whole point of the
        // check is that the thing now on disk loads.
        if (!tools.probe(exe)) {
            std.log.err("{s}: installed at {s} but it does not load", .{ tool.title(), exe });
            failed = true;
            continue;
        }

        std.log.info("{s} installed at {s}", .{ tool.title(), exe });
    }

    // Exit rather than return: everything is already reported in terms a person
    // can act on, and returning would add a Zig stack trace that says nothing.
    if (failed) std.process.exit(1);
}

test {
    // A test build analyses only what a test reaches: without `&main` nothing
    // below it here is compiled, and the imports collect each file's own tests.
    _ = &main;
    _ = @import("./tools.zig");
    _ = @import("./model.zig");
    _ = @import("./message.zig");
    _ = @import("./renderer.zig");
    _ = @import("./components/text_view.zig");
    _ = @import("./components/editor.zig");
    _ = @import("./fff.zig");
    _ = @import("./components/tabs.zig");
    _ = @import("./components/vtuple.zig");
    _ = @import("./components/workbench.zig");
    _ = @import("./components/columns.zig");
    _ = @import("./components/tree.zig");
    _ = @import("./glyph_atlas.zig");
}
