//! The sidebar file tree: cmd+B, click a folder to open it, click a file to
//! open it in the column with the keyboard.
//!
//! It holds no listing of its own. `model.sidebar` is the whole of what the
//! index found, sorted by path, and the folders the reader has opened over it;
//! this folds that flat list into a hierarchy, shapes the rows on screen, and
//! turns a press back into the row it landed in.
//!
//! The fold is redone only when the listing or the open folders change, which
//! `model.sidebar.revision` says: a scroll moves the same rows, and a redraw of
//! them shapes nothing that was shaped before.
//!
//! Files come in flat -- `src/main.zig`, not a `src` with a `main.zig` under it
//! -- so the folders are the path prefixes. A folder with no files under it is
//! not in the index and so not here, which is the one thing this shows less of
//! than the disk holds.

const std = @import("std");

const config = @import("../config.zig");
const message_mod = @import("../message.zig");
const Message = message_mod.Message;
const Change = message_mod.Change;

const glyph_atlas = @import("../glyph_atlas.zig");
const Model = @import("../model.zig").Model;
const GlyphAtlas = glyph_atlas.GlyphAtlas;
const LineLayout = glyph_atlas.LineLayout;

const painter_mod = @import("../painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const drawLine = @import("../text.zig").draw;
const advance = @import("../text.zig").advance;

/// The ground, the rule that closes it off on the right, and the words. The
/// ground and the rule cannot share a layer: the ground covers the whole strip,
/// the rule sits at its right edge, and within a layer the painter reorders, so
/// the rule would draw under the ground it is meant to sit on.
const ground_key: Key = .{ .layer = 0, .pipeline = .solid, .colour = config.chip_colour };
const rule_key: Key = .{ .layer = 1, .pipeline = .solid, .colour = config.edge_colour };
const name_key: Key = .{ .layer = 2, .pipeline = .glyphs, .colour = config.text_colour };

/// The folder marker, said quietly: it is a hint about what a row does, not part
/// of the name.
const chevron_key: Key = .{ .layer = 2, .pipeline = .glyphs, .colour = config.muted_colour };

/// A folder open, and a folder shut. Two glyphs, shaped once and set down again
/// for every folder on screen.
const chevron_open_glyph = "\u{25BE}";
const chevron_shut_glyph = "\u{25B8}";

/// In points, scaled like the font: the air at the left edge and above a row,
/// how far one level of nesting steps in, and the gap between the marker and the
/// name.
const pad = 6;
const indent_step = 14;
const gap = 4;

/// Rows are set a little looser than the font's own line so the list reads as
/// set rather than stacked.
const leading = 1.3;

/// One line of the folded tree. The strings are the model's -- `path` is the
/// listing's own slice, `name` its last segment -- and live until the next
/// fold, which is exactly as long as a row does.
const Row = struct {
    path: []const u8,
    name: []const u8,
    depth: u16,
    is_dir: bool,
};

/// A node while the hierarchy is being built. Lives in the fold's arena and is
/// gone by the time it returns; the rows it produces point at the model instead.
const Node = struct {
    name: []const u8,
    full: []const u8,
    is_dir: bool,
    children: std.StringArrayHashMapUnmanaged(*Node) = .empty,
};

pub const Tree = struct {
    /// The folded rows, top to bottom, and a shaped line for each. Parallel:
    /// `layouts[i]` is `rows[i]` set in glyphs, shaped the first time it is
    /// drawn and not before.
    rows: std.ArrayList(Row) = .empty,
    layouts: std.ArrayList(LineLayout) = .empty,

    /// Which revision the rows were folded from, or none before the first fold.
    /// When it falls behind the model's, the fold is redone.
    built: ?u32 = null,

    /// The two markers, shaped once each.
    chevron_open: LineLayout = .{},
    chevron_shut: LineLayout = .{},

    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        for (self.layouts.items) |*layout| layout.deinit(allocator);
        self.layouts.deinit(allocator);
        self.rows.deinit(allocator);
        self.chevron_open.deinit(allocator);
        self.chevron_shut.deinit(allocator);
    }

    pub fn place(self: *Tree, _: *const Model, rect: Rect) void {
        self.rect = rect;
    }

    /// How tall one row is. A number of the font's own lines, so it grows with
    /// the display's scale without anyone here converting.
    fn step(model: *const Model) f32 {
        return @round(model.atlas.line_height * leading);
    }

    /// Folds the flat listing into rows, once per revision. The old rows and the
    /// glyphs shaped for them are let go of first: a fold is a new set of rows,
    /// not an edit of the last.
    fn rebuild(self: *Tree, model: *const Model) !void {
        const allocator = model.allocator;

        for (self.layouts.items) |*layout| layout.deinit(allocator);
        self.rows.clearRetainingCapacity();
        self.layouts.clearRetainingCapacity();

        // The nodes and their maps live only as long as the fold. The rows that
        // come out of it point at the model's paths, which outlast it.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try fold(allocator, arena.allocator(), model.sidebar.paths.items, &model.sidebar.expanded, &self.rows);

        try self.layouts.resize(allocator, self.rows.items.len);
        for (self.layouts.items) |*layout| layout.* = .{};

        self.built = model.sidebar.revision;
    }

    fn ensureBuilt(self: *Tree, model: *const Model) !void {
        if (self.built == null or self.built.? != model.sidebar.revision) try self.rebuild(model);
    }

    /// What a press means: a folder to open or shut, a file to open, or nothing
    /// when it fell past the last row. A wheel moves the list, clamped here
    /// because only this knows how many rows there are.
    pub fn update(self: *Tree, model: *const Model, message: Message) !Change {
        try self.ensureBuilt(model);
        const s = step(model);

        switch (message) {
            .press => |what| {
                const y = what.at[1] - self.rect.y + model.sidebar.scroll;
                if (y < 0) return .none;
                const index: usize = @intFromFloat(@floor(y / s));
                if (index >= self.rows.items.len) return .none;

                const row = self.rows.items[index];
                return if (row.is_dir) .{ .toggle_dir = row.path } else .{ .open_file = row.path };
            },
            .wheel => |wheel| {
                const content = @as(f32, @floatFromInt(self.rows.items.len)) * s;
                const furthest = @max(0, content - self.rect.height);
                const to = std.math.clamp(model.sidebar.scroll + wheel.delta, 0, furthest);
                if (to == model.sidebar.scroll) return .none;
                return .{ .scroll_tree = to };
            },
            else => return .none,
        }
    }

    pub fn draw(self: *Tree, model: *const Model, painter: *Painter) !void {
        try self.ensureBuilt(model);

        // So a row scrolled up cannot draw above the strip, and a name too long
        // for it cannot draw into the files beside it.
        painter.clipTo(self.rect);
        defer painter.clipTo(null);

        const line = @max(1, @round(model.atlas.scale));
        try painter.add(ground_key, .solid(
            .{ self.rect.x, self.rect.y },
            .{ self.rect.width, self.rect.height },
        ));
        try painter.add(rule_key, .solid(
            .{ self.rect.x + self.rect.width - line, self.rect.y },
            .{ line, self.rect.height },
        ));

        if (self.rows.items.len == 0) return;

        if (model.atlas.stale(&self.chevron_open)) try model.atlas.shapeLine(chevron_open_glyph, &self.chevron_open);
        if (model.atlas.stale(&self.chevron_shut)) try model.atlas.shapeLine(chevron_shut_glyph, &self.chevron_shut);

        // Reserved on every row whether it carries a marker or not, so a file
        // and the folder above it line their names up.
        const marker = @round(@max(advance(&self.chevron_open), advance(&self.chevron_shut)) + gap * model.atlas.scale);

        const s = step(model);
        const inset = @round(pad * model.atlas.scale);
        const indent = @round(indent_step * model.atlas.scale);
        const scroll = model.sidebar.scroll;

        // Only the rows on screen are shaped, and only those. The first is
        // whatever the scroll has carried up past the top edge.
        const first: usize = @intFromFloat(@max(0, @floor(scroll / s)));
        var index = first;
        while (index < self.rows.items.len) : (index += 1) {
            const top = @round(self.rect.y + @as(f32, @floatFromInt(index)) * s - scroll);
            if (top >= self.rect.y + self.rect.height) break;

            const row = self.rows.items[index];
            const layout = &self.layouts.items[index];
            if (layout.sprites.items.len == 0 or model.atlas.stale(layout)) {
                try model.atlas.shapeLine(row.name, layout);
            }

            const baseline = @round(top + (s - model.atlas.line_height) / 2 + model.atlas.ascent);
            const left = self.rect.x + inset + @as(f32, @floatFromInt(row.depth)) * indent;

            if (row.is_dir) {
                const open = model.sidebar.expanded.contains(row.path);
                const chevron = if (open) &self.chevron_open else &self.chevron_shut;
                try drawLine(painter, chevron_key, chevron, .{ left, baseline });
            }

            try drawLine(painter, name_key, layout, .{ left + marker, baseline });
        }
    }
};

/// Folds sorted file paths into rows, folders before files, opening a folder's
/// contents only when it is in `expanded`.
///
/// `gpa` is where the rows go and outlives the call; `arena` holds the tree of
/// nodes and is thrown away as this returns. The rows point at the paths, so
/// they last as long as the listing does.
fn fold(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    paths: []const []const u8,
    expanded: *const std.StringHashMapUnmanaged(void),
    rows: *std.ArrayList(Row),
) !void {
    var root: std.StringArrayHashMapUnmanaged(*Node) = .empty;

    for (paths) |path| {
        var into = &root;
        var start: usize = 0;
        var at: usize = 0;
        while (at <= path.len) : (at += 1) {
            if (at < path.len and path[at] != '/') continue;

            // A leading or doubled separator is not a segment.
            if (at == start) {
                start = at + 1;
                continue;
            }

            const segment = path[start..at];
            // More of the path to come means this segment is a folder.
            const is_dir = at < path.len;

            const found = try into.getOrPut(arena, segment);
            if (!found.found_existing) {
                const node = try arena.create(Node);
                node.* = .{ .name = segment, .full = path[0..at], .is_dir = is_dir };
                found.value_ptr.* = node;
            }
            into = &found.value_ptr.*.children;
            start = at + 1;
        }
    }

    try emit(gpa, arena, &root, 0, expanded, rows);
}

/// Walks one level, folders first, and descends into the open ones.
fn emit(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    level: *std.StringArrayHashMapUnmanaged(*Node),
    depth: u16,
    expanded: *const std.StringHashMapUnmanaged(void),
    rows: *std.ArrayList(Row),
) !void {
    // A copy, because the map's own order is the order paths arrived in and this
    // wants folders first.
    const ordered = try arena.dupe(*Node, level.values());
    std.mem.sort(*Node, ordered, {}, lessNode);

    for (ordered) |node| {
        try rows.append(gpa, .{ .path = node.full, .name = node.name, .depth = depth, .is_dir = node.is_dir });
        if (node.is_dir and expanded.contains(node.full)) {
            try emit(gpa, arena, &node.children, depth + 1, expanded, rows);
        }
    }
}

/// Folders before files, and each group by name.
fn lessNode(_: void, a: *Node, b: *Node) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.mem.lessThan(u8, a.name, b.name);
}

const testing = std.testing;

/// The rows a fold produces for a listing, with the given folders open. The
/// caller frees the returned list; the arena holds the scratch and is freed
/// here.
fn foldedWith(
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    open: []const []const u8,
) !std.ArrayList(Row) {
    var expanded: std.StringHashMapUnmanaged(void) = .empty;
    defer expanded.deinit(gpa);
    for (open) |dir| try expanded.put(gpa, dir, {});

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(gpa);
    try fold(gpa, arena.allocator(), paths, &expanded, &rows);
    return rows;
}

test "a closed tree shows only the top level, folders first" {
    const gpa = testing.allocator;
    var rows = try foldedWith(gpa, &.{
        "src/main.zig",
        "src/model.zig",
        "README.md",
        "assets/font.ttf",
    }, &.{});
    defer rows.deinit(gpa);

    // assets and src are folders and sort ahead of the one file; nothing under
    // them shows, because neither is open.
    try testing.expectEqual(@as(usize, 3), rows.items.len);
    try testing.expectEqualStrings("assets", rows.items[0].name);
    try testing.expect(rows.items[0].is_dir);
    try testing.expectEqualStrings("src", rows.items[1].name);
    try testing.expectEqualStrings("README.md", rows.items[2].name);
    try testing.expect(!rows.items[2].is_dir);
}

test "opening a folder shows its contents, indented, and only that folder's" {
    const gpa = testing.allocator;
    var rows = try foldedWith(gpa, &.{
        "src/main.zig",
        "src/model.zig",
        "README.md",
        "assets/font.ttf",
    }, &.{"src"});
    defer rows.deinit(gpa);

    // src is open: its two files appear under it, one level in. assets stays
    // shut, so its file does not.
    try testing.expectEqual(@as(usize, 5), rows.items.len);
    try testing.expectEqualStrings("assets", rows.items[0].name);
    try testing.expectEqualStrings("src", rows.items[1].name);
    try testing.expectEqualStrings("main.zig", rows.items[2].name);
    try testing.expectEqual(@as(u16, 1), rows.items[2].depth);
    try testing.expectEqualStrings("model.zig", rows.items[3].name);
    try testing.expectEqualStrings("README.md", rows.items[4].name);
}

test "a folder stays shut unless every folder above it is open" {
    const gpa = testing.allocator;

    // The nested folder is named, but its parent is not open, so it is not on
    // screen to open in the first place.
    var rows = try foldedWith(gpa, &.{"src/components/tree.zig"}, &.{"src/components"});
    defer rows.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("src", rows.items[0].name);

    // With the parent open too, the chain unfolds all the way down.
    var deep = try foldedWith(gpa, &.{"src/components/tree.zig"}, &.{ "src", "src/components" });
    defer deep.deinit(gpa);

    try testing.expectEqual(@as(usize, 3), deep.items.len);
    try testing.expectEqualStrings("components", deep.items[1].name);
    try testing.expectEqualStrings("tree.zig", deep.items[2].name);
    try testing.expectEqual(@as(u16, 2), deep.items[2].depth);
    // The folder's row carries the path the model opens it by, not just its name.
    try testing.expectEqualStrings("src/components", deep.items[1].path);
}
