//! The sidebar file tree: cmd+B, click a folder to open it, click a file to
//! open it in the column with the keyboard.
//!
//! It holds no listing of its own: `model.sidebar` is the flat, sorted index and
//! the open folders, which this folds into a hierarchy, shapes, and hit-tests.
//! The fold is redone only when `model.sidebar.revision` moves.
//!
//! Paths come in flat, so the folders are their prefixes; a folder with no files
//! under it is not in the index and so not shown.

const std = @import("std");

const message_mod = @import("../message.zig");
const Message = message_mod.Message;

const model_mod = @import("../model.zig");
const Model = model_mod.Model;
const Row = model_mod.Row;

const painter_mod = @import("../painter.zig");
const Key = painter_mod.Key;
const Painter = painter_mod.Painter;
const Rect = painter_mod.Rect;

const drawLine = @import("../text.zig").draw;
const advance = @import("../text.zig").advance;

/// Ground and rule need separate layers: the ground covers the strip and the
/// rule sits at its edge, and within a layer the painter would reorder them.
const ground_key: Key = .{ .layer = 0, .pipeline = .solid, .colour = .chip };
const rule_key: Key = .{ .layer = 1, .pipeline = .solid, .colour = .edge };
const name_key: Key = .{ .layer = 2, .pipeline = .glyphs, .colour = .text };
const chevron_key: Key = .{ .layer = 2, .pipeline = .glyphs, .colour = .muted };

const chevron_open_glyph = "\u{25BE}";
const chevron_shut_glyph = "\u{25B8}";

const pad = 6;
const indent_step = 14;
const gap = 4;
const leading = 1.3;

/// A node while the hierarchy is being built: lives in the fold's arena and is
/// gone by the time it returns, so its rows point at the model's paths instead.
const Node = struct {
    name: []const u8,
    full: []const u8,
    is_dir: bool,
    children: std.StringArrayHashMapUnmanaged(*Node) = .empty,
};

pub const Tree = struct {
    pub fn deinit(_: *Tree, _: std.mem.Allocator) void {}

    /// Folds the listing, shapes the markers and the on-screen rows, and records
    /// the strip -- all into `model.sidebar`, so `resolve` and `draw` only read.
    pub fn place(_: *Tree, model: *Model, rect: Rect) !void {
        model.sidebar.rect = rect;
        try ensureBuilt(model);

        const sidebar = &model.sidebar;
        if (sidebar.rows.items.len == 0) return;

        if (model.atlas.stale(&sidebar.chevron_open)) try model.atlas.shapeLine(chevron_open_glyph, &sidebar.chevron_open);
        if (model.atlas.stale(&sidebar.chevron_shut)) try model.atlas.shapeLine(chevron_shut_glyph, &sidebar.chevron_shut);

        // Only the rows on screen are shaped, and only those.
        const s = step(model);
        var index: usize = @intFromFloat(@max(0, @floor(sidebar.scroll / s)));
        while (index < sidebar.rows.items.len) : (index += 1) {
            const top = @round(rect.y + @as(f32, @floatFromInt(index)) * s - sidebar.scroll);
            if (top >= rect.y + rect.height) break;

            const layout = &sidebar.layouts.items[index];
            if (layout.sprites.items.len == 0 or model.atlas.stale(layout)) {
                try model.atlas.shapeLine(sidebar.rows.items[index].name, layout);
            }
        }
    }

    /// A press to a folder to toggle or a file to open; a wheel to a clamped
    /// scroll. A free function: `Model.update` calls it with the model it holds.
    pub fn resolve(model: *const Model, message: Message) Message {
        const sidebar = &model.sidebar;
        const s = step(model);

        switch (message) {
            .press => |what| {
                const y = what.at[1] - sidebar.rect.y + sidebar.scroll;
                if (y < 0) return .none;
                const index: usize = @intFromFloat(@floor(y / s));
                if (index >= sidebar.rows.items.len) return .none;

                const row = sidebar.rows.items[index];
                return if (row.is_dir) .{ .toggle_dir = row.path } else .{ .open_file = row.path };
            },
            .wheel => |wheel| {
                const content = @as(f32, @floatFromInt(sidebar.rows.items.len)) * s;
                const furthest = @max(0, content - sidebar.rect.height);
                const to = std.math.clamp(sidebar.scroll + wheel.delta, 0, furthest);
                if (to == sidebar.scroll) return .none;
                return .{ .scroll_tree = to };
            },
            else => return .none,
        }
    }

    pub fn draw(_: *Tree, model: *const Model, painter: *Painter) !void {
        const sidebar = &model.sidebar;
        const rect = sidebar.rect;

        // So a scrolled row cannot draw above the strip, nor a long name into
        // the files beside it.
        painter.clipTo(rect);
        defer painter.clipTo(null);

        const line = @max(1, @round(model.atlas.scale));
        try painter.add(ground_key, .solid(.{ rect.x, rect.y }, .{ rect.width, rect.height }));
        try painter.add(rule_key, .solid(
            .{ rect.x + rect.width - line, rect.y },
            .{ line, rect.height },
        ));

        if (sidebar.rows.items.len == 0) return;

        // Reserved on every row, marker or not, so files and folders line up.
        const marker = @round(@max(advance(&sidebar.chevron_open), advance(&sidebar.chevron_shut)) + gap * model.atlas.scale);

        const s = step(model);
        const inset = @round(pad * model.atlas.scale);
        const indent = @round(indent_step * model.atlas.scale);
        const scroll = sidebar.scroll;

        // Only the rows on screen, which `place` has already shaped.
        var index: usize = @intFromFloat(@max(0, @floor(scroll / s)));
        while (index < sidebar.rows.items.len) : (index += 1) {
            const top = @round(rect.y + @as(f32, @floatFromInt(index)) * s - scroll);
            if (top >= rect.y + rect.height) break;

            const row = sidebar.rows.items[index];
            const layout = &sidebar.layouts.items[index];

            const baseline = @round(top + (s - model.atlas.line_height) / 2 + model.atlas.ascent);
            const left = rect.x + inset + @as(f32, @floatFromInt(row.depth)) * indent;

            if (row.is_dir) {
                const open = sidebar.expanded.contains(row.path);
                const chevron = if (open) &sidebar.chevron_open else &sidebar.chevron_shut;
                try drawLine(painter, chevron_key, chevron, .{ left, baseline });
            }

            try drawLine(painter, name_key, layout, .{ left + marker, baseline });
        }
    }

    /// How tall one row is, as a number of the font's lines.
    fn step(model: *const Model) f32 {
        return @round(model.atlas.line_height * leading);
    }

    /// Folds the flat listing into rows, once per revision, freeing the old rows
    /// and their glyphs first.
    fn ensureBuilt(model: *Model) !void {
        const sidebar = &model.sidebar;
        if (sidebar.built != null and sidebar.built.? == sidebar.revision) return;

        const allocator = model.allocator;
        for (sidebar.layouts.items) |*layout| layout.deinit(allocator);
        sidebar.rows.clearRetainingCapacity();
        sidebar.layouts.clearRetainingCapacity();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try fold(allocator, arena.allocator(), sidebar.paths.items, &sidebar.expanded, &sidebar.rows);

        try sidebar.layouts.resize(allocator, sidebar.rows.items.len);
        for (sidebar.layouts.items) |*layout| layout.* = .{};

        sidebar.built = sidebar.revision;
    }
};

/// Folds sorted paths into rows, folders before files, opening a folder only
/// when it is in `expanded`. The rows go in `gpa` and point at the paths; the
/// node tree lives in `arena` and is thrown away here.
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

/// Walks one level, folders first, descending into the open ones.
fn emit(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    level: *std.StringArrayHashMapUnmanaged(*Node),
    depth: u16,
    expanded: *const std.StringHashMapUnmanaged(void),
    rows: *std.ArrayList(Row),
) !void {
    // A copy, since the map's own order is the order paths arrived in.
    const ordered = try arena.dupe(*Node, level.values());
    std.mem.sort(*Node, ordered, {}, lessNode);

    for (ordered) |node| {
        try rows.append(gpa, .{ .path = node.full, .name = node.name, .depth = depth, .is_dir = node.is_dir });
        if (node.is_dir and expanded.contains(node.full)) {
            try emit(gpa, arena, &node.children, depth + 1, expanded, rows);
        }
    }
}

fn lessNode(_: void, a: *Node, b: *Node) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.mem.lessThan(u8, a.name, b.name);
}

const testing = std.testing;

/// The rows a fold produces, with the given folders open. Caller frees the list.
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

    // Folders sort ahead of the file, and nothing under them shows.
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

    // src is open, so its files appear indented under it; assets stays shut.
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
