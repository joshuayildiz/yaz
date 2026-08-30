//! What the window shows when yaz cannot run.
//!
//! ripgrep and fzf are not optional -- the finder is built on them -- so a
//! startup that cannot run both puts this up instead of an editor and turns
//! everything else off. It says which tool is missing, where it was looked for,
//! and what to type.
//!
//! It never changes while it is up: the probe runs once, at startup, so
//! installing the tools in another terminal means starting yaz again.

const std = @import("std");

const config = @import("./config.zig");
const Event = @import("./event.zig").Event;

const glyph_atlas = @import("./glyph_atlas.zig");
const GlyphAtlas = glyph_atlas.GlyphAtlas;
const LineLayout = glyph_atlas.LineLayout;

const painter_mod = @import("./painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const tools = @import("./tools.zig");

const text_key: Key = .{ .layer = 0, .pipeline = .glyphs, .colour = config.text_colour };

/// Where the block starts, in points. Scaled like everything else that is
/// measured in points rather than pixels.
const margin: [2]f32 = .{ 24, 16 };

pub const Healthcheck = struct {
    gpa: std.mem.Allocator,

    /// What to draw, one entry per line, owned here. Built once in `init`,
    /// because what is missing cannot change while this is on screen.
    lines: std.ArrayList([]u8) = .empty,

    /// Shaped lazily on the first frame, and again after a scale change, the
    /// same way a view's layout cache is.
    layouts: std.ArrayList(LineLayout) = .empty,

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    /// True to begin with: it has never been drawn.
    dirty: bool = true,

    pub fn init(
        gpa: std.mem.Allocator,
        environ: std.process.Environ,
        missing: tools.Missing,
    ) !Healthcheck {
        var self: Healthcheck = .{ .gpa = gpa };
        errdefer self.deinit();

        try self.say("yaz cannot start: it needs ripgrep and fzf.", .{});
        try self.say("", .{});

        // No columns to line up. The font is proportional, so padding with
        // spaces would leave a ragged edge rather than a straight one.
        for (tools.Tool.all) |tool| {
            const where = try tools.path(gpa, environ, tool);
            defer gpa.free(where);

            try self.say("    {s} \u{2014} {s} \u{2014} {s}", .{
                tool.title(),
                if (missing.has(tool)) "missing" else "ok",
                where,
            });
        }

        try self.say("", .{});
        try self.say("Run  yaz setup  to install them, then start yaz again.", .{});

        try self.layouts.appendNTimes(gpa, .{}, self.lines.items.len);
        return self;
    }

    fn say(self: *Healthcheck, comptime format: []const u8, args: anytype) !void {
        const line = try std.fmt.allocPrint(self.gpa, format, args);
        errdefer self.gpa.free(line);
        try self.lines.append(self.gpa, line);
    }

    pub fn deinit(self: *Healthcheck) void {
        for (self.lines.items) |line| self.gpa.free(line);
        self.lines.deinit(self.gpa);

        for (self.layouts.items) |*entry| {
            entry.sprites.deinit(self.gpa);
            entry.carets.deinit(self.gpa);
        }
        self.layouts.deinit(self.gpa);
    }

    pub fn place(self: *Healthcheck, rect: Rect) void {
        self.rect = rect;
    }

    /// Nothing here reacts to anything. Quit and resize belong to the window and
    /// have been dealt with above; every other event is for an editor that is
    /// not running.
    pub fn update(self: *Healthcheck, event: Event) void {
        _ = self;
        _ = event;
    }

    pub fn isDirty(self: *const Healthcheck) bool {
        return self.dirty;
    }

    pub fn setDirty(self: *Healthcheck, value: bool) void {
        self.dirty = value;
    }

    /// Every shaped line goes, for after the atlas is rebuilt at a different
    /// scale, for the reason `Document.invalidate` gives.
    pub fn invalidate(self: *Healthcheck) void {
        for (self.layouts.items) |*entry| entry.shaped = false;
        self.dirty = true;
    }

    pub fn draw(self: *Healthcheck, atlas: *GlyphAtlas, painter: *Painter) !void {
        painter.clipTo(self.rect);
        defer painter.clipTo(null);

        // Whole pixels, which the shaped layout depends on: a fractional origin
        // would change which subpixel variant every cached glyph points at.
        const x = @round(self.rect.x + margin[0] * atlas.scale);
        const top = @round(self.rect.y + margin[1] * atlas.scale);

        for (self.layouts.items, self.lines.items, 0..) |*entry, line, index| {
            if (!entry.shaped) try atlas.shapeLine(line, entry);

            const down = @as(f32, @floatFromInt(index)) * atlas.line_height;
            const baseline = @round(top + down + atlas.ascent);

            try painter.reserve(entry.sprites.items.len);
            for (entry.sprites.items) |sprite| {
                try painter.add(text_key, .{
                    .dest = .{ sprite.dest[0] + x, sprite.dest[1] + baseline },
                    .source = sprite.source,
                    .size = sprite.size,
                });
            }
        }
    }
};
