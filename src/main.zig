const std = @import("std");

const Renderer = @import("./renderer.zig").Renderer;
const displayScale = @import("./renderer.zig").displayScale;
const Context = @import("./context.zig").Context;
const event_mod = @import("./event.zig");
const Event = event_mod.Event;
const Painter = @import("./painter.zig").Painter;
const sdl = @import("./sdl.zig");
const tools = @import("./tools.zig");
const Healthcheck = @import("./components/healthcheck.zig").Healthcheck;
const Finder = @import("./components/finder.zig").Finder;
const ZTuple = @import("./components/ztuple.zig").ZTuple;
const Tabs = @import("./components/tabs.zig").Tabs;
const TextView = @import("./components/text_view.zig").TextView;
const workbench_mod = @import("./components/workbench.zig");
const Workbench = workbench_mod.Workbench;
const Views = workbench_mod.Views;
const c = sdl.c;

/// `setup` prints, so it has to be heard from in a release build too, where the
/// default would keep everything below an error to itself.
pub const std_options: std.Options = .{ .log_level = .info };

/// Back to front. The finder sits behind the workbench until cmd+P brings it
/// forward, so opening and closing it is a change of order and nothing else.
const Editing = ZTuple(&.{ Finder, Workbench });

pub fn main(init: std.process.Init) !void {
    if (try wantsSetup(init)) return setup(init);

    var cx: Context = .{ .allocator = init.gpa, .io = init.io };
    defer cx.deinit();

    // The tools before anything else: with either of them missing nothing but
    // the healthcheck runs, and reading a file first would report the wrong
    // problem when the path is also bad.
    const absent = try tools.missing(cx.allocator, cx.io, init.minimal.environ);
    if (absent.any()) {
        const stopped = try Healthcheck.init(cx.allocator, init.minimal.environ, absent);
        return run(&cx, Healthcheck, stopped, null);
    }

    // Read out here rather than inside `run`, so a file that cannot be opened
    // fails before a window has appeared and gone again. Nothing a component is
    // built from needs a window.
    var views = try openColumns(&cx, init);
    errdefer views.deinit(&cx);

    // Borrowed rather than copied: `run` hands it to SDL, which copies it, and
    // the context outlives the call.
    const title = views.items.items[0].file.path;

    const finder = try Finder.init(cx.allocator, init.minimal.environ);
    return run(&cx, Editing, .init(.{ finder, .init(.{}, views) }), title);
}

/// A column per file named, left to right in the order they were named.
///
/// The files themselves go into the context, which owns them; a column only
/// points at one. A window given nothing to open gets a blank file, so there is
/// always something to type into.
fn openColumns(cx: *Context, init: std.process.Init) !Views {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, cx.allocator);
    defer args.deinit();
    _ = args.skip(); // The program itself.

    var views: Views = .{};
    errdefer views.deinit(cx);

    // Read one at a time rather than gathering the paths first: the iterator
    // owns what it returns until the next call, and `open` copies it.
    while (args.next()) |named| {
        try views.append(cx, .init(try cx.open(named)));
    }

    if (views.items.items.len == 0) {
        try views.append(cx, .init(try cx.blank()));
    }
    return views;
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

        cx: *Context,
        renderer: Renderer,
        painter: Painter,
        component: Component,

        /// What has changed at this level, as against inside the component.
        /// True to begin with: the first frame has never been drawn.
        dirty: bool = true,

        fn deinit(self: *Self) void {
            self.component.deinit(self.cx);
            self.painter.deinit();
            self.renderer.deinit();
        }

        fn isDirty(self: *const Self) bool {
            return self.dirty or self.component.isDirty();
        }

        fn setDirty(self: *Self, value: bool) void {
            self.dirty = value;
            self.component.setDirty(value);
        }

        /// Two events belong to the window itself and the rest belong to what
        /// is in it. What changed is not answered here; it is asked for
        /// afterwards, through `isDirty`.
        fn update(self: *Self, event: Event) !void {
            switch (event) {
                .quit => {
                    self.cx.running = false;
                    return;
                },
                .resized => {
                    self.dirty = true;
                    return;
                },
                else => {},
            }

            // What nobody in the tree took. A path belongs to whoever takes it,
            // so one that comes all the way back out is this to free.
            switch (try self.component.update(self.cx, event)) {
                .open, .only => |path| self.cx.allocator.free(path),
                else => {},
            }
        }

        fn redraw(self: *Self) !void {
            // Read rather than listened for: three window events can imply the
            // scale changed, and dragging to another display happens inside the
            // modal loop, where only the watch below runs.
            const scale = displayScale(self.renderer.window);
            if (try self.renderer.atlas.setScale(scale)) {
                self.cx.invalidate();
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
            self.component.place(self.cx, .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(width),
                .height = @floatFromInt(height),
            });

            self.painter.clear();
            try self.component.draw(self.cx, &self.painter);
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
fn run(cx: *Context, comptime Component: type, component: Component, title: ?[]const u8) !void {
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
        .cx = cx,
        .renderer = try Renderer.init(cx.allocator, window),
        .painter = .init(cx.allocator),
        .component = component,
    };
    defer app.deinit();

    // The atlas cannot be named before now: the renderer owns it, and the
    // renderer needs a window. Nothing has placed, drawn or measured yet.
    cx.atlas = &app.renderer.atlas;

    // Only a window with a file in it has anything to be called. SDL copies the
    // string, so the sentinel it wants is borrowed for the length of the call
    // rather than carried around by the view -- where it would be a path whose
    // allocation is one byte longer than its length, and the parked documents
    // are keyed by exactly that path.
    if (title) |named| {
        const owned = try cx.allocator.dupeZ(u8, named);
        defer cx.allocator.free(owned);
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
    while (cx.running) {
        if (app.isDirty()) {
            try app.redraw();
            app.setDirty(false);
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
            if (Event.init(&event, density)) |what| try app.update(what);
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

        if (tools.probe(init.gpa, init.io, exe)) {
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
        // check is that the thing now on disk runs.
        if (!tools.probe(init.gpa, init.io, exe)) {
            std.log.err("{s}: installed at {s} but it does not run", .{ tool.title(), exe });
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
    _ = @import("./context.zig");
    _ = @import("./event.zig");
    _ = @import("./renderer.zig");
    _ = @import("./components/text_view.zig");
    _ = @import("./components/ztuple.zig");
    _ = @import("./components/htuple.zig");
    _ = @import("./components/hlist.zig");
    _ = @import("./components/tabs.zig");
    _ = @import("./components/vtuple.zig");
    _ = @import("./components/workbench.zig");
}
