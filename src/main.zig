const std = @import("std");

const Renderer = @import("./renderer.zig").Renderer;
const displayScale = @import("./renderer.zig").displayScale;
const Model = @import("./model.zig").Model;
const message_mod = @import("./message.zig");
const Message = message_mod.Message;
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

    // Built once, and the whole of what the window is showing. Everything
    // below reads its state out of this and writes changes back into it.
    var model: Model = .init(init);
    defer model.deinit();

    // The tools before anything else: with either of them missing nothing but
    // the healthcheck runs, and reading a file first would report the wrong
    // problem when the path is also bad.
    //
    // Opening the library is the check. It used to be two `--version` spawns
    // of two 4MB binaries, which cost 11ms of every launch (OPTIMIZATIONS 12);
    // this is the same library the finder is about to use, opened once, and
    // every symbol has to resolve before it counts as working.
    model.locate(init.minimal.environ) catch |err| switch (err) {
        error.CannotOpenLibrary, error.MissingSymbol, error.CannotIndex => {
            const stopped = try Healthcheck.init(model.allocator, init.minimal.environ, .{ .fff = true });
            return run(&model, Healthcheck, stopped, null);
        },
        else => |other| return other,
    };

    // Read out here rather than inside `run`, so a file that cannot be opened
    // fails before a window has appeared and gone again. Nothing a component is
    // built from needs a window.
    try model.openNamed(init);

    // A column per file named, left to right in the order they were named.
    try model.columns.appendSlice(model.allocator, model.files.items);

    // Borrowed rather than copied: `run` hands it to SDL, which copies it, and
    // the context outlives the call.
    const title = model.files.items[0].path;

    return run(&model, Editor, .{}, title);
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
            self.component.deinit(self.model);
            self.painter.deinit();
            self.renderer.deinit();
        }

        /// Two events belong to the window itself and the rest belong to what
        /// is in it. What changed is not answered here; it is asked for
        /// afterwards, through `Model.dirty`.
        /// One message in, one effect out, one change made. Quit is the
        /// window's own; a resize changes nothing in the model and only wants
        /// the frame drawn again.
        fn update(self: *Self, message: Message) !void {
            switch (message) {
                .quit => return self.model.apply(.quit),
                .resized => return self.model.apply(.nothing_but_draw),
                else => {},
            }

            try self.model.apply(try self.component.update(self.model, message));
        }

        fn redraw(self: *Self) !void {
            // Read rather than listened for: three window events can imply the
            // scale changed, and dragging to another display happens inside the
            // modal loop, where only the watch below runs.
            const scale = displayScale(self.renderer.window);
            if (try self.renderer.atlas.setScale(scale)) {
                self.model.invalidate();
                self.component.invalidate();
            }

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
fn run(model: *Model, comptime Component: type, component: Component, title: ?[]const u8) !void {
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

    // After `SDL_Init`, which is when the menu bar it takes this from is built.
    sdl.unbindCloseShortcut();

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

    // Only a window with a file in it has anything to be called. SDL copies the
    // string, so the sentinel it wants is borrowed for the length of the call
    // rather than carried around by the file, where it would be a path one byte
    // longer than its length for the sake of one call at startup.
    if (title) |named| {
        const owned = try model.allocator.dupeZ(u8, named);
        defer model.allocator.free(owned);
        _ = c.SDL_SetWindowTitle(window, owned.ptr);
    }

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
            if (Message.init(&event, density)) |what| try app.update(what);
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
}
