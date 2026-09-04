const std = @import("std");

const Renderer = @import("./renderer.zig").Renderer;
const displayScale = @import("./renderer.zig").displayScale;
const Model = @import("./model.zig").Model;
const message_mod = @import("./message.zig");
const Message = message_mod.Message;
const Change = message_mod.Change;
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

/// The window, and the one component `main` put in it.
///
/// Generic over that component, so a window that is one thing costs no more
/// than one thing. Nothing here asks what that component is: an event it does
/// not own itself goes into the tree, and what the tree cannot deal with comes
/// back out.
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

        /// Two events belong to the window itself and the rest belong to what
        /// is in it. What changed is not answered here; it is asked for
        /// afterwards, through `Model.dirty`.
        /// One message in, one change out, one thing moved. Quit is the
        /// window's own; a resize changes nothing in the model and only wants
        /// the frame drawn again.
        fn update(self: *Self, message: Message) !void {
            switch (message) {
                .quit => return self.change(.quit),
                .resized => return self.change(.redraw),
                // The window's, not a column's: which file was waiting for a
                // name is the model's to remember.
                .named => |path| return self.change(.{ .name_it = path }),
                else => {},
            }

            try self.change(try self.component.update(self.model, message));
        }

        /// Moves the model, and does whatever the move left to be done.
        ///
        /// The model comes back from `update` rather than being written
        /// through, so this is the one place it is put down again. Nothing else
        /// holds a copy: everything reads it through this same pointer.
        fn change(self: *Self, what: Change) !void {
            const next, const effect = try self.model.update(what);
            self.model.* = next;

            if (effect) |asked| try self.perform(asked);
        }

        /// The other half of `Change`'s other half: what the model asked for and
        /// could not do itself.
        ///
        /// Everything here either ends in a file or on the clipboard, or comes
        /// back round as another change. That is what keeps `Model.update` free
        /// of SDL and of the filesystem, which is what lets it be tested
        /// without either.
        /// `anyerror` because this and `change` call each other -- an effect can
        /// end in a change and a change can ask for another effect -- and two
        /// inferred error sets that each depend on the other cannot be worked
        /// out. Naming one of them breaks the loop.
        fn perform(self: *Self, effect: Effect) anyerror!void {
            switch (effect) {
                .batch => |these| {
                    defer self.model.allocator.free(these);
                    for (these) |each| try self.perform(each);
                },

                // Reported rather than returned, all three of them. A clipboard
                // that will not take text, a file that cannot be written --
                // read-only, no room, a directory gone -- is something to be
                // told about, and for a save the mark staying on its tab is the
                // rest of the telling. An error here would take the window down
                // over one file.
                .copy => |which| self.model.copyOut(which) catch |err| {
                    std.log.err("copy: {s}", .{@errorName(err)});
                },

                .paste => |which| {
                    const text = self.model.clipboard() catch |err| {
                        std.log.err("paste: {s}", .{@errorName(err)});
                        return;
                    } orelse return;
                    defer self.model.allocator.free(text);

                    // An ordinary insert from here on, which is what makes
                    // pasting over a selection replace it without asking.
                    try self.change(.{ .insert = .{ .column = which, .text = text } });
                },

                .save => |which| {
                    const file = self.model.column(which) orelse return;
                    self.model.writeOut(file) catch |err| {
                        std.log.err("{s}: {s}", .{ file.path.?, @errorName(err) });
                        return;
                    };
                    try self.change(.{ .saved = which });
                },

                // Modal to the window, and asynchronous: the answer arrives as
                // an event, whenever whoever is looking at it decides.
                .ask_name => sdl.askWhereToSave(self.renderer.window),

                // Start and stop the watch that keeps the tree live. Out here
                // rather than in the model because starting it registers a
                // callback that pushes an SDL event.
                .watch => self.model.watchTree(),
                .unwatch => self.model.unwatchTree(),
            }
        }

        fn redraw(self: *Self) !void {
            // Read rather than listened for: three window events can imply the
            // scale changed, and dragging to another display happens inside the
            // modal loop, where only the watch below runs.
            // Nobody is told about it. Everything shaped carries the
            // generation of the atlas that shaped it, so what was cached before
            // a rebuild answers `stale` for itself, wherever it is kept.
            const scale = displayScale(self.renderer.window);
            try self.renderer.atlas.setScale(scale);

            // The window rather than the swapchain, which is not acquired until
            // `present`. The two can disagree for a frame mid-resize, which is
            // one line too many or too few.
            var width: c_int = 0;
            var height: c_int = 0;
            _ = c.SDL_GetWindowSizeInPixels(self.renderer.window, &width, &height);

            // Everything gets the whole window. A component that divides it --
            // the columns -- does that itself; one that lies over it -- the
            // finder -- wants all of it.
            self.component.place(self.model, .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(width),
                .height = @floatFromInt(height),
            });

            self.painter.clear();
            try self.component.draw(self.model, &self.painter);
            try self.renderer.present(&self.painter);

            // After the frame it belongs to: a look worked out where its match
            // ended up on screen while placing the columns, and the pointer is
            // moved there now that the match is actually shown.
            self.warpPending();
        }

        /// Moves the pointer to wherever a look asked it to go. In window
        /// coordinates, which is what the request is divided back into: the
        /// selection's place was worked out in pixels, and the cursor is the one
        /// thing SDL still speaks to in points.
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
                // Swallowed: the main loop draws again the moment it gets
                // control back and surfaces the failure there.
                app.redraw() catch {};
            }
            // Watch callbacks cannot filter; the return value is ignored.
            return true;
        }
    };
}

/// Puts a window up and runs `component` in it until it is closed.
fn run(model: *Model, comptime Component: type, component: Component) !void {
    // macOS makes inertial scroll events of its own and SDL turns them off
    // unless asked. Asking costs nothing while nothing is moving: momentum is
    // more wheel events, and they stop arriving when it stops. Before
    // `SDL_Init`, which is when SDL reads it.
    _ = c.SDL_SetHint(c.SDL_HINT_MAC_SCROLL_MOMENTUM, "1");

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.err("SDL_Init: {s}", .{sdl.lastError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    // Before `SDL_Quit`, since the watcher's callback pushes SDL events: let the
    // subscription go while there is still something to push into. A no-op when
    // the tree was never opened, which is why it can sit here for every window.
    defer model.unwatchTree();

    // After `SDL_Init`, which is when the menu bar it takes this from is built.
    sdl.unbindCloseShortcut();

    // After it too: the event type a save dialog answers on is claimed from
    // SDL's pool. Without one there is no way to hear back, so a file with no
    // name would ask and never learn the answer.
    if (!sdl.registerEvents()) {
        std.log.err("SDL_RegisterEvents: {s}", .{sdl.lastError()});
        return error.SdlRegisterEvents;
    }

    // The size is in window coordinates. Without `HIGH_PIXEL_DENSITY` the back
    // buffer is that size too and the finished frame is scaled up to the
    // display, which no amount of care in the text pipeline survives.
    const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    const window = c.SDL_CreateWindow("yaz", 1024, 768, flags) orelse {
        std.log.err("SDL_CreateWindow: {s}", .{sdl.lastError()});
        return error.SdlCreateWindow;
    };
    defer c.SDL_DestroyWindow(window);

    std.log.info("video driver: {s}", .{std.mem.span(c.SDL_GetCurrentVideoDriver())});

    // Text arrives as finished characters rather than keys. The platform's
    // input method gets the keystrokes first, so a dead key, a compose
    // sequence or a CJK conversion has already become the character it means
    // by the time it reaches us.
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

    // The last thing the context was missing: the renderer owns the atlas, and
    // the renderer needs a window. Nothing has placed, drawn or measured yet.
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

        // Everything already queued belongs to the frame this wakeup produces.
        // Folding a burst into one redraw is what stops a keystroke queueing up
        // behind presents of unchanged content: presenting blocks on the
        // swapchain, so each redundant one costs real latency, not just work.
        while (true) {
            const density = c.SDL_GetWindowPixelDensity(window);
            const line_height = app.renderer.atlas.line_height;

            // A save dialog's answer owns the path it carries, and the message
            // made from it only borrows one. Let go of here, in a block of its
            // own, because the poll below overwrites the event this is holding.
            {
                defer sdl.releasePath(&event);
                if (Message.init(&event, density, line_height)) |what| try app.update(what);
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

    // Exiting rather than returning the error: everything that went wrong has
    // already been reported in terms a person can act on, and returning it would
    // add a Zig stack trace that says nothing they can.
    if (failed) std.process.exit(1);
}

test {
    // A test build analyses only what a test reaches. Without the first line
    // nothing below `main` in this file is compiled at all, which is how a green
    // `zig build test` has twice been followed by a failing `zig build`.
    //
    // The imports are separate from it: reaching a file's functions is not the
    // same as collecting its tests, and tools.zig's had never run.
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
    _ = @import("./components/tree.zig");
    _ = @import("./glyph_atlas.zig");
}
