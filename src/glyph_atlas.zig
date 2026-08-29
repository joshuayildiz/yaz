//! Everything between a line of text and the pixels the GPU samples for it:
//! shaping the bytes into positioned glyph ids, rasterising the ones the atlas
//! does not hold yet, uploading those, and resolving the result into quads.
//!
//! It is one file because it is one pipeline. Shaping decides which glyphs
//! exist, so it is the only thing that can say what to rasterise; rasterising
//! decides where they land in the atlas, so it is the only thing that can say
//! what to sample. Splitting those apart would mean each half telling the other
//! what it just learned.

const std = @import("std");

const sdl = @import("./sdl.zig");
const c = sdl.c;

const config = @import("./config.zig");

const ft = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

const hb = @cImport({
    @cInclude("hb.h");
});

/// Embedded rather than discovered on the system, so every platform renders
/// the same pixels and there is no font-matching code to get wrong. Which file
/// this is comes from config.zig, by way of the build.
const font_data = @embedFile("font");

/// Proportional advances put glyph origins on fractional pixels. Rasterising
/// each glyph at four horizontal offsets lets a quad stay pixel-aligned while
/// the origin it represents does not, which is what keeps stems from wobbling
/// as text reflows. Four is the usual stopping point: the atlas grows linearly
/// in this number and the difference past a quarter of a pixel is not visible.
const subpixel_positions = 4;

/// The atlas starts empty and fills as glyphs are asked for. Nothing else works
/// once text is shaped: `fi` is one glyph in this font, and no character maps to
/// it, so no walk over characters would ever rasterise it. Shaping decides what
/// exists, and it can only be asked at the point the text is laid out.
///
/// One texture, sized so the glyphs a document actually uses fit without paging.
/// A megabyte of single-channel coverage. The sample text's 46 distinct glyphs
/// reach 82 of these 1024 rows, which puts the ceiling somewhere near 500 -- far
/// past what a page of English needs, and short of a CJK document, which will
/// want eviction or a second page rather than a bigger number here.
const atlas_width = 1024;
const atlas_height = 1024;

/// A slot is an atlased glyph and its `subpixel_positions` variants. The cap
/// exists so the metrics are one flat array rather than a growable one, and is
/// deliberately past what the atlas can hold: running out of texture is the
/// limit that should bite, and it reports itself the same way.
const max_slots = 1024;

/// `GlyphAtlas.slots` holds one of these per glyph the font defines, so most entries
/// stay `no_slot` forever.
const no_slot = std.math.maxInt(u16);

/// One rasterised glyph. `left` and `top` are the offset from the pen origin to
/// the bitmap's top-left corner, in pixels, y counting downwards; FreeType has
/// already folded the subpixel shift into them and into the coverage itself.
const Glyph = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    left: i16 = 0,
    top: i16 = 0,
};

/// One glyph resolved to what the GPU needs: where the quad goes on screen and
/// where to sample it from. Both are in whole pixels -- the fraction of the pen
/// position went into choosing which subpixel variant to point at.
///
/// `extern` because an array of these is copied to the GPU as it stands and
/// indexed by the vertex shader; the field order here is the struct declared
/// there. renderer.zig holds the test that says so.
pub const Sprite = extern struct {
    dest: [2]f32,
    source: [2]f32,
    size: [2]f32,
};

/// One line's shaped sprites, held in coordinates of the line's own: x from
/// where the line starts, y from its baseline. Nothing in here knows where the
/// line sits on screen, which is what lets a line that only moved down keep its
/// layout instead of being shaped again.
const LineLayout = struct {
    sprites: std.ArrayList(Sprite) = .empty,

    /// The length of the text this was shaped from. A cache that has drifted
    /// out of step with the document would otherwise draw the wrong line
    /// rather than say so.
    bytes: usize = 0,

    shaped: bool = false,
};

/// The atlas texture's dimensions, which the vertex shader needs to turn a
/// source rectangle into texture coordinates.
pub const size: [2]f32 = .{ atlas_width, atlas_height };

/// The font as the GPU sees it: coverage for the glyphs asked for so far, at
/// every subpixel offset, plus the metrics needed to place them.
///
/// Entries are keyed by `(glyph id, subpixel)`, because two origins a quarter
/// of a pixel apart are genuinely different pictures, not the same picture
/// moved. That pair is the identity of a rasterised glyph.
///
/// FreeType stays open for the life of the font rather than being closed once
/// an atlas is built, because there is no longer a moment when the atlas is
/// finished. A glyph nobody has typed yet has not been rasterised yet.
pub const GlyphAtlas = struct {
    gpa: std.mem.Allocator,
    gpu: *c.SDL_GPUDevice,
    library: ft.FT_Library,
    face: ft.FT_Face,
    texture: *c.SDL_GPUTexture,
    shaper: Shaper,

    /// Where every glyph of the current frame goes. Cleared rather than freed
    /// between frames: it settles at the size of a screenful and stops
    /// allocating, which is what keeps a redraw free of the allocator.
    sprites: std.ArrayList(Sprite) = .empty,

    /// One entry per line of the document, in the document's order. Shaping is
    /// the expensive half of laying out a line and it only depends on the
    /// line's bytes, so it is done once and kept.
    cache: std.ArrayList(LineLayout) = .empty,

    /// Glyph id to a slot in `glyphs`, or one of the two sentinels. One entry
    /// per glyph in the font, which is kilobytes, so the lookup is an index
    /// rather than a hash: this runs once per glyph drawn.
    slots: []u16,
    glyphs: []Glyph,
    used: u16 = 0,

    /// A shelf packer: fill a row left to right, start a new row when the next
    /// glyph will not fit. Glyphs at one pixel size are close enough in height
    /// that the wasted strip above the short ones is not worth a better fit.
    shelf_x: u16 = 0,
    shelf_y: u16 = 0,
    shelf_height: u16 = 0,

    /// Coverage rasterised this frame and not yet on the GPU. Uploading is a
    /// copy pass, and a copy pass cannot be opened inside a render pass, so the
    /// misses are collected first and sent in one go before drawing starts.
    staging: std.ArrayList(u8) = .empty,
    uploads: std.ArrayList(Upload) = .empty,

    ascent: f32,
    line_height: f32,

    const Placed = struct { x: u16, y: u16 };

    const Upload = struct {
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        offset: u32,
    };

    pub fn init(gpa: std.mem.Allocator, gpu: *c.SDL_GPUDevice) !GlyphAtlas {
        var library: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&library) != 0) return error.FreetypeInit;
        errdefer _ = ft.FT_Done_FreeType(library);

        // From memory, not from a path: the font is part of the binary.
        var face: ft.FT_Face = null;
        if (ft.FT_New_Memory_Face(library, font_data, font_data.len, 0, &face) != 0) {
            return error.FreetypeNewFace;
        }
        errdefer _ = ft.FT_Done_Face(face);

        if (ft.FT_Set_Pixel_Sizes(face, 0, config.font_pixel_size) != 0) {
            return error.FreetypeSetPixelSizes;
        }

        const slots = try gpa.alloc(u16, @intCast(face.*.num_glyphs));
        errdefer gpa.free(slots);
        @memset(slots, no_slot);

        const glyphs = try gpa.alloc(Glyph, max_slots * subpixel_positions);
        errdefer gpa.free(glyphs);

        var shaper = try Shaper.init();
        errdefer shaper.deinit();

        return .{
            .gpa = gpa,
            .gpu = gpu,
            .library = library,
            .face = face,
            .texture = try createAtlas(gpa, gpu),
            .shaper = shaper,
            .slots = slots,
            .glyphs = glyphs,
            .ascent = fromFixed(face.*.size.*.metrics.ascender),
            .line_height = fromFixed(face.*.size.*.metrics.height),
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        c.SDL_ReleaseGPUTexture(self.gpu, self.texture);
        self.shaper.deinit();
        for (self.cache.items) |*entry| entry.sprites.deinit(self.gpa);
        self.cache.deinit(self.gpa);
        self.sprites.deinit(self.gpa);
        self.uploads.deinit(self.gpa);
        self.staging.deinit(self.gpa);
        self.gpa.free(self.glyphs);
        self.gpa.free(self.slots);
        _ = ft.FT_Done_Face(self.face);
        _ = ft.FT_Done_FreeType(self.library);
    }

    /// Resolves every line into sprites, shaping the ones whose text has
    /// changed since they were last seen and rasterising whatever glyphs that
    /// turns up. `top` is the top of the first line, not its baseline.
    ///
    /// A redraw that changed nothing shapes nothing; a keystroke shapes the one
    /// line it landed in. What is left per frame is placing the cached sprites,
    /// which has to happen anyway to fill the buffer the GPU reads.
    pub fn layout(self: *GlyphAtlas, lines: []const []const u8, x: f32, top: f32) !void {
        // Cached sprites are placed by adding whole pixels. A fractional
        // origin would change which subpixel variant each glyph points at, and
        // the cache would be answering the wrong question.
        std.debug.assert(x == @round(x));

        self.sprites.clearRetainingCapacity();
        if (self.cache.items.len == 0) try self.cache.appendNTimes(self.gpa, .{}, lines.len);
        // Anything else means an edit went unreported and the entries no longer
        // line up with the lines they describe.
        std.debug.assert(self.cache.items.len == lines.len);

        var baseline = top + self.ascent;
        for (lines, self.cache.items) |line, *entry| {
            if (!entry.shaped) try self.shapeLine(line, entry);
            std.debug.assert(entry.bytes == line.len);

            const origin: [2]f32 = .{ x, @round(baseline) };
            try self.sprites.ensureUnusedCapacity(self.gpa, entry.sprites.items.len);
            for (entry.sprites.items) |sprite| {
                self.sprites.appendAssumeCapacity(.{
                    .dest = .{ sprite.dest[0] + origin[0], sprite.dest[1] + origin[1] },
                    .source = sprite.source,
                    .size = sprite.size,
                });
            }

            baseline += self.line_height;
        }
    }

    /// Brings the cache back into step with the document after an edit, told
    /// what that edit did to the line index: which line it landed in, how many
    /// lines after it stopped existing, and how many came into being.
    ///
    /// Every other entry survives untouched. A line that moved down the screen
    /// is the same shaped line at a different baseline, which is the whole
    /// reason the sprites are kept in coordinates of their own.
    pub fn splice(self: *GlyphAtlas, line: usize, removed: usize, added: usize) !void {
        // Nothing has been laid out yet, so there is nothing to keep in step.
        if (self.cache.items.len == 0) return;
        try spliceLines(self.gpa, &self.cache, line, removed, added);
    }

    /// Shapes one line into coordinates of its own: x from where the line
    /// starts, y from its baseline.
    fn shapeLine(self: *GlyphAtlas, text: []const u8, entry: *LineLayout) !void {
        entry.sprites.clearRetainingCapacity();

        const shaped = self.shaper.shape(text);
        var pen: f32 = 0;
        for (shaped.infos, shaped.positions) |info, offset| {
            try self.request(info.codepoint);

            // The offset moves a glyph off the pen without moving the pen,
            // which is how marks land on the letters they belong to. Latin
            // leaves it at zero; something else will not.
            const position = quantize(pen + fromFixed(offset.x_offset));
            pen += fromFixed(offset.x_advance);

            // Nothing to draw for a space, but the pen has already moved past
            // it, which is the whole of what it contributes.
            const g = self.glyph(info.codepoint, position.subpixel) orelse continue;
            try entry.sprites.append(self.gpa, .{
                .dest = .{
                    position.pixel + @as(f32, @floatFromInt(g.left)),
                    -@round(fromFixed(offset.y_offset)) - @as(f32, @floatFromInt(g.top)),
                },
                .source = .{ @floatFromInt(g.x), @floatFromInt(g.y) },
                .size = .{ @floatFromInt(g.width), @floatFromInt(g.height) },
            });
        }

        entry.bytes = text.len;
        entry.shaped = true;
    }

    /// Rasterises `id` if this is the first time it has been asked for. Both the
    /// expensive path and the do-nothing path go through here, once per glyph
    /// laid out; after a line's first redraw every call is a load and a compare.
    fn request(self: *GlyphAtlas, id: u32) !void {
        // Not a glyph this face defines, or already decided one way or another.
        if (id >= self.slots.len or self.slots[id] != no_slot) return;

        // `max_slots` is set past what the texture can hold, so the atlas
        // should always run out first.
        if (self.used == max_slots) {
            std.debug.panic("glyph atlas is out of slots at {d}, asked for glyph {d}", .{ max_slots, id });
        }

        const slot = self.used;
        for (0..subpixel_positions) |subpixel| {
            // FreeType translates the outline before rasterising, so the
            // fractional offset ends up in the coverage rather than being
            // approximated by moving the finished bitmap.
            var delta: ft.FT_Vector = .{
                .x = @intCast(subpixel * 64 / subpixel_positions),
                .y = 0,
            };
            ft.FT_Set_Transform(self.face, null, &delta);

            if (ft.FT_Load_Glyph(self.face, id, ft.FT_LOAD_RENDER) != 0) {
                // The font is compiled in, so a glyph it will not rasterise
                // is a broken build rather than bad input.
                std.debug.panic("FreeType cannot render glyph {d}", .{id});
            }
            const rendered = self.face.*.glyph;
            const bitmap = rendered.*.bitmap;

            // A space rasterises to nothing. It still takes a slot, so that the
            // next lookup is a hit rather than another trip through FreeType.
            if (bitmap.width == 0 or bitmap.rows == 0) {
                self.glyphs[glyphIndex(slot, subpixel)] = .{};
                continue;
            }

            const width: u16 = @intCast(bitmap.width);
            const height: u16 = @intCast(bitmap.rows);
            // TODO: fixed size, no eviction, so a document with more distinct
            // glyphs than fit lands here -- CJK long before Latin. Either raise
            // `atlas_width` and `atlas_height`, which moves the wall, or grow
            // at runtime: allocate a larger texture, re-run the shelf packer
            // over the ids already in `slots`, and re-rasterise each into it.
            // FreeType stays open for the life of the font, so growing needs no
            // CPU copy of the atlas kept around for it.
            const placed = self.pack(width, height) orelse std.debug.panic(
                "glyph atlas is full: no room for glyph {d} at {d}x{d} in {d}x{d}, {d} glyphs in",
                .{ id, width, height, atlas_width, atlas_height, self.used },
            );

            // Rows sit `pitch` bytes apart, which is not `width`: FreeType pads
            // them, and copying the buffer whole would shear the glyph. What
            // goes to the GPU is tight, one row after another.
            const offset: u32 = @intCast(self.staging.items.len);
            const pitch: usize = @intCast(bitmap.pitch);
            try self.staging.ensureUnusedCapacity(self.gpa, @as(usize, width) * height);
            for (0..height) |row| {
                self.staging.appendSliceAssumeCapacity((bitmap.buffer + row * pitch)[0..width]);
            }
            try self.uploads.append(self.gpa, .{
                .x = placed.x,
                .y = placed.y,
                .width = width,
                .height = height,
                .offset = offset,
            });

            self.glyphs[glyphIndex(slot, subpixel)] = .{
                .x = placed.x,
                .y = placed.y,
                .width = width,
                .height = height,
                .left = @intCast(rendered.*.bitmap_left),
                .top = @intCast(rendered.*.bitmap_top),
            };
        }

        self.slots[id] = slot;
        self.used += 1;
    }

    /// Finds room for one bitmap and reserves it. Null when the atlas is full,
    /// which is permanent: nothing is ever evicted.
    fn pack(self: *GlyphAtlas, width: u16, height: u16) ?Placed {
        if (width > atlas_width) return null;
        if (self.shelf_x + width > atlas_width) {
            self.shelf_x = 0;
            self.shelf_y += self.shelf_height;
            self.shelf_height = 0;
        }
        if (@as(u32, self.shelf_y) + height > atlas_height) return null;

        const placed: Placed = .{ .x = self.shelf_x, .y = self.shelf_y };
        self.shelf_x += width;
        self.shelf_height = @max(self.shelf_height, height);
        return placed;
    }

    /// Sends everything rasterised since the last call. Empty on all but the
    /// first redraw of a given piece of text, and the early return is what keeps
    /// a steady-state frame free of transfers.
    pub fn upload(self: *GlyphAtlas) !void {
        const gpu = self.gpu;
        if (self.uploads.items.len == 0) return;
        defer {
            self.uploads.clearRetainingCapacity();
            self.staging.clearRetainingCapacity();
        }

        const transfer = c.SDL_CreateGPUTransferBuffer(gpu, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = @as(u32, @intCast(self.staging.items.len)),
        })) orelse {
            std.log.err("SDL_CreateGPUTransferBuffer: {s}", .{sdl.lastError()});
            return error.SdlCreateTransferBuffer;
        };
        defer c.SDL_ReleaseGPUTransferBuffer(gpu, transfer);

        const mapped = c.SDL_MapGPUTransferBuffer(gpu, transfer, false) orelse {
            std.log.err("SDL_MapGPUTransferBuffer: {s}", .{sdl.lastError()});
            return error.SdlMapTransferBuffer;
        };
        @memcpy(@as([*]u8, @ptrCast(mapped))[0..self.staging.items.len], self.staging.items);
        c.SDL_UnmapGPUTransferBuffer(gpu, transfer);

        const cmd = c.SDL_AcquireGPUCommandBuffer(gpu) orelse {
            std.log.err("SDL_AcquireGPUCommandBuffer: {s}", .{sdl.lastError()});
            return error.SdlAcquireCommandBuffer;
        };
        const pass = c.SDL_BeginGPUCopyPass(cmd);
        for (self.uploads.items) |queued| {
            // Tight rows, which Vulkan and Metal both take as given. D3D12
            // would want them padded to 256 bytes, and the shader format the
            // build pins means SDL never selects it.
            const source = std.mem.zeroInit(c.SDL_GPUTextureTransferInfo, .{
                .transfer_buffer = transfer,
                .offset = queued.offset,
                .pixels_per_row = @as(u32, queued.width),
                .rows_per_layer = @as(u32, queued.height),
            });
            const destination = std.mem.zeroInit(c.SDL_GPUTextureRegion, .{
                .texture = self.texture,
                .x = @as(u32, queued.x),
                .y = @as(u32, queued.y),
                .w = @as(u32, queued.width),
                .h = @as(u32, queued.height),
                .d = 1,
            });
            c.SDL_UploadToGPUTexture(pass, &source, &destination, false);
        }
        c.SDL_EndGPUCopyPass(pass);

        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
            std.log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdl.lastError()});
            return error.SdlSubmit;
        }
    }

    fn glyph(self: *const GlyphAtlas, id: u32, subpixel: usize) ?Glyph {
        // Laying a glyph out requests it, and a request that could not be met
        // panicked there.
        std.debug.assert(id < self.slots.len);
        const slot = self.slots[id];
        std.debug.assert(slot != no_slot);

        const found = self.glyphs[glyphIndex(slot, subpixel)];
        // A space rasterises to nothing; there is no quad to draw for it.
        return if (found.width == 0) null else found;
    }
};

/// The splice itself, apart from the atlas so that it can be tested without a
/// GPU to build one on.
fn spliceLines(
    gpa: std.mem.Allocator,
    cache: *std.ArrayList(LineLayout),
    line: usize,
    removed: usize,
    added: usize,
) !void {
    const first = line + 1;
    std.debug.assert(first + removed <= cache.items.len);

    // Reserved before anything moves, so a failure cannot leave the cache a
    // different length from the document it describes.
    try cache.ensureUnusedCapacity(gpa, added);

    for (cache.items[first..][0..removed]) |*entry| entry.sprites.deinit(gpa);
    std.mem.copyForwards(LineLayout, cache.items[first..], cache.items[first + removed ..]);
    cache.items.len -= removed;

    cache.items.len += added;
    std.mem.copyBackwards(
        LineLayout,
        cache.items[first + added ..],
        cache.items[first .. cache.items.len - added],
    );
    for (cache.items[first..][0..added]) |*entry| entry.* = .{};

    // The line the edit landed in kept its place and lost its text.
    cache.items[line].shaped = false;
}

/// Four lines, each holding one sprite so that dropping an entry without
/// freeing it shows up as a leak.
fn testCache(gpa: std.mem.Allocator) !std.ArrayList(LineLayout) {
    var cache: std.ArrayList(LineLayout) = .empty;
    for ([_]usize{ 10, 20, 30, 40 }) |bytes| {
        var entry: LineLayout = .{ .bytes = bytes, .shaped = true };
        try entry.sprites.append(gpa, .{ .dest = .{ 0, 0 }, .source = .{ 0, 0 }, .size = .{ 1, 1 } });
        try cache.append(gpa, entry);
    }
    return cache;
}

fn testFree(gpa: std.mem.Allocator, cache: *std.ArrayList(LineLayout)) void {
    for (cache.items) |*entry| entry.sprites.deinit(gpa);
    cache.deinit(gpa);
}

test "an edit inside one line leaves every other line's layout alone" {
    const gpa = std.testing.allocator;
    var cache = try testCache(gpa);
    defer testFree(gpa, &cache);

    try spliceLines(gpa, &cache, 1, 0, 0);

    try std.testing.expectEqual(4, cache.items.len);
    try std.testing.expectEqualSlices(usize, &.{ 10, 20, 30, 40 }, &.{
        cache.items[0].bytes, cache.items[1].bytes, cache.items[2].bytes, cache.items[3].bytes,
    });
    try std.testing.expectEqualSlices(bool, &.{ true, false, true, true }, &.{
        cache.items[0].shaped, cache.items[1].shaped, cache.items[2].shaped, cache.items[3].shaped,
    });
}

test "splitting a line shifts the ones below it without reshaping them" {
    const gpa = std.testing.allocator;
    var cache = try testCache(gpa);
    defer testFree(gpa, &cache);

    // A newline typed into line 1.
    try spliceLines(gpa, &cache, 1, 0, 1);

    try std.testing.expectEqual(5, cache.items.len);
    try std.testing.expect(!cache.items[1].shaped);
    try std.testing.expect(!cache.items[2].shaped);
    // Lines 2 and 3 are the same shaped lines, one index further down.
    try std.testing.expectEqual(30, cache.items[3].bytes);
    try std.testing.expect(cache.items[3].shaped);
    try std.testing.expectEqual(40, cache.items[4].bytes);
    try std.testing.expect(cache.items[4].shaped);
}

test "joining two lines drops one entry and reshapes the survivor" {
    const gpa = std.testing.allocator;
    var cache = try testCache(gpa);
    defer testFree(gpa, &cache);

    // Backspace at the start of line 2, joining it onto line 1.
    try spliceLines(gpa, &cache, 1, 1, 0);

    try std.testing.expectEqual(3, cache.items.len);
    try std.testing.expectEqual(10, cache.items[0].bytes);
    try std.testing.expect(!cache.items[1].shaped);
    try std.testing.expectEqual(40, cache.items[2].bytes);
    try std.testing.expect(cache.items[2].shaped);
}

test "deleting across lines collapses them onto the one the edit started in" {
    const gpa = std.testing.allocator;
    var cache = try testCache(gpa);
    defer testFree(gpa, &cache);

    try spliceLines(gpa, &cache, 0, 3, 0);

    try std.testing.expectEqual(1, cache.items.len);
    try std.testing.expect(!cache.items[0].shaped);
}

/// Where `(slot, subpixel)` lives in `GlyphAtlas.glyphs`.
fn glyphIndex(slot: u16, subpixel: usize) usize {
    // Widened before the multiply, which overflows a u16 well inside the range
    // of slot counts the atlas can hold.
    const index: usize = slot;
    return index * subpixel_positions + subpixel;
}

test "glyphIndex does not wrap for late slots" {
    try std.testing.expectEqual(@as(usize, 0), glyphIndex(0, 0));
    try std.testing.expectEqual(@as(usize, 260), glyphIndex(65, 0));
    try std.testing.expectEqual(
        @as(usize, max_slots * subpixel_positions - 1),
        glyphIndex(max_slots - 1, subpixel_positions - 1),
    );
}

/// Splits a pen position into the pixel a quad lands on and the subpixel variant
/// to sample from. Rounding rather than truncating: an origin 0.24 of a pixel
/// along is nearer the quarter-pixel rasterisation than the whole-pixel one.
fn quantize(pen: f32) struct { pixel: f32, subpixel: usize } {
    const steps = @round(pen * subpixel_positions);
    const whole = @floor(steps / subpixel_positions);
    return .{
        .pixel = whole,
        .subpixel = @intFromFloat(steps - whole * subpixel_positions),
    };
}

test "quantize splits a pen position into pixel and subpixel" {
    try std.testing.expectEqual(@as(usize, 0), quantize(4.0).subpixel);
    try std.testing.expectEqual(@as(usize, 1), quantize(4.25).subpixel);
    try std.testing.expectEqual(@as(usize, 3), quantize(4.75).subpixel);
    try std.testing.expectEqual(@as(f32, 4), quantize(4.75).pixel);

    // Nearest, not floor: just under a quarter still selects the quarter.
    try std.testing.expectEqual(@as(usize, 1), quantize(4.24).subpixel);

    // Rounding up past the last offset carries into the next whole pixel
    // rather than producing a fifth variant.
    try std.testing.expectEqual(@as(f32, 5), quantize(4.9).pixel);
    try std.testing.expectEqual(@as(usize, 0), quantize(4.9).subpixel);

    // Left of the origin the split still has to hold.
    try std.testing.expectEqual(@as(f32, -1), quantize(-0.3).pixel);
    try std.testing.expectEqual(@as(usize, 3), quantize(-0.3).subpixel);
}

/// Turns bytes into glyph ids and the positions to draw them at. This is the
/// step proportional text cannot do without: advances differ per character and
/// kerning depends on which characters are adjacent, so a pen position is
/// accumulated from what shaping returns, never computed from a column.
///
/// HarfBuzz reads the font tables directly here rather than going through
/// FreeType. `hb-ft` would report advances the way FreeType does, rounded to
/// whole pixels once hinting is on — and a whole pixel is exactly the fraction
/// the subpixel atlas exists to render. Reading the tables keeps advances
/// fractional, so every pen position lands somewhere the atlas has a variant
/// for. Glyph ids agree either way: they are a property of the file.
const Shaper = struct {
    font: *hb.hb_font_t,
    /// Reused across lines. Shaping is on the path from a keystroke to a
    /// redraw, and this is the allocation it would otherwise make every time.
    buffer: *hb.hb_buffer_t,

    fn init() !Shaper {
        const blob = hb.hb_blob_create(
            font_data,
            font_data.len,
            hb.HB_MEMORY_MODE_READONLY,
            null,
            null,
        ) orelse return error.HarfbuzzCreateBlob;
        // The face takes a reference; this one has done its job either way.
        defer hb.hb_blob_destroy(blob);

        const face = hb.hb_face_create(blob, 0) orelse return error.HarfbuzzCreateFace;
        defer hb.hb_face_destroy(face);

        const font = hb.hb_font_create(face) orelse return error.HarfbuzzCreateFont;
        errdefer hb.hb_font_destroy(font);
        // Font units until told otherwise. Scaling by 64 asks for positions in
        // 26.6 fixed point, which is what FreeType reports metrics in, so the
        // two halves of the pipeline agree without a conversion between them.
        hb.hb_font_set_scale(font, config.font_pixel_size * 64, config.font_pixel_size * 64);

        const buffer = hb.hb_buffer_create() orelse return error.HarfbuzzCreateBuffer;
        return .{ .font = font, .buffer = buffer };
    }

    fn deinit(self: *Shaper) void {
        hb.hb_buffer_destroy(self.buffer);
        hb.hb_font_destroy(self.font);
    }

    const Shaped = struct {
        infos: []const hb.hb_glyph_info_t,
        positions: []const hb.hb_glyph_position_t,
    };

    /// Shapes one line. The result borrows the shared buffer, so it is only
    /// valid until the next call.
    fn shape(self: *Shaper, text: []const u8) Shaped {
        hb.hb_buffer_clear_contents(self.buffer);
        hb.hb_buffer_add_utf8(self.buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));

        // Left to right, strictly and by decision: there is no bidi pass and
        // there is not going to be one. Right-to-left text will shape its
        // joining forms correctly and then be set down backwards.
        //
        // The language is stated rather than guessed because
        // `hb_buffer_guess_segment_properties` would take it from the system
        // locale, and the whole point of embedding the font is that every
        // machine draws the same pixels. The script tag is the one shortcut
        // here; see the direction notes in README.md for what it costs, which
        // with this font is nothing measurable.
        hb.hb_buffer_set_direction(self.buffer, hb.HB_DIRECTION_LTR);
        hb.hb_buffer_set_script(self.buffer, hb.HB_SCRIPT_LATIN);
        hb.hb_buffer_set_language(self.buffer, hb.hb_language_from_string("en", -1));

        hb.hb_shape(self.font, self.buffer, null, 0);

        var count: c_uint = 0;
        const infos = hb.hb_buffer_get_glyph_infos(self.buffer, &count);
        const positions = hb.hb_buffer_get_glyph_positions(self.buffer, &count);
        return .{ .infos = infos[0..count], .positions = positions[0..count] };
    }
};

/// How wide a run shapes to. Only the tests measure text so far; hit-testing
/// (step 13) is what needs it in earnest, and needs it per cluster.
fn shapedWidth(shaper: *Shaper, text: []const u8) f32 {
    var total: f32 = 0;
    for (shaper.shape(text).positions) |position| total += fromFixed(position.x_advance);
    return total;
}

test "shaping kerns a pair that plain advances would set too far apart" {
    var shaper = try Shaper.init();
    defer shaper.deinit();

    // A and V lean into each other, so the pair is narrower than the two
    // letters measured alone. Nothing but the kerning table makes that true,
    // which is what makes it worth asserting: if shaping silently stopped
    // applying it, every other test here would still pass.
    const together = shapedWidth(&shaper, "AV");
    const apart = shapedWidth(&shaper, "A") + shapedWidth(&shaper, "V");
    try std.testing.expect(together < apart);
}

test "shaping returns one glyph per character for unkerned Latin" {
    var shaper = try Shaper.init();
    defer shaper.deinit();

    const text = "quick";
    const shaped = shaper.shape(text);
    try std.testing.expectEqual(text.len, shaped.infos.len);
    // Cluster values are byte offsets into the text, which is what cursor
    // positions will eventually be compared against.
    for (shaped.infos, 0..) |info, i| try std.testing.expectEqual(@as(u32, @intCast(i)), info.cluster);
}

/// FreeType reports most metrics in 26.6 fixed point: pixels times 64. So does
/// HarfBuzz, once its font is scaled to match, hence the two integer types.
fn fromFixed(value: anytype) f32 {
    return @as(f32, @floatFromInt(value)) / 64.0;
}

/// Creates the atlas texture and zeroes it. Nothing samples outside a glyph's
/// own rectangle, so the clear is not load-bearing today; it costs one upload at
/// startup and means the texture never holds anything nobody wrote.
fn createAtlas(gpa: std.mem.Allocator, gpu: *c.SDL_GPUDevice) !*c.SDL_GPUTexture {
    const texture = c.SDL_CreateGPUTexture(gpu, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = atlas_width,
        .height = atlas_height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
    })) orelse {
        std.log.err("SDL_CreateGPUTexture: {s}", .{sdl.lastError()});
        return error.SdlCreateTexture;
    };
    errdefer c.SDL_ReleaseGPUTexture(gpu, texture);

    const blank = try gpa.alloc(u8, atlas_width * atlas_height);
    defer gpa.free(blank);
    @memset(blank, 0);

    const transfer = c.SDL_CreateGPUTransferBuffer(gpu, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @as(u32, @intCast(blank.len)),
    })) orelse {
        std.log.err("SDL_CreateGPUTransferBuffer: {s}", .{sdl.lastError()});
        return error.SdlCreateTransferBuffer;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(gpu, transfer);

    const mapped = c.SDL_MapGPUTransferBuffer(gpu, transfer, false) orelse {
        std.log.err("SDL_MapGPUTransferBuffer: {s}", .{sdl.lastError()});
        return error.SdlMapTransferBuffer;
    };
    @memcpy(@as([*]u8, @ptrCast(mapped))[0..blank.len], blank);
    c.SDL_UnmapGPUTransferBuffer(gpu, transfer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(gpu) orelse {
        std.log.err("SDL_AcquireGPUCommandBuffer: {s}", .{sdl.lastError()});
        return error.SdlAcquireCommandBuffer;
    };
    const pass = c.SDL_BeginGPUCopyPass(cmd);
    const source = std.mem.zeroInit(c.SDL_GPUTextureTransferInfo, .{
        .transfer_buffer = transfer,
        .pixels_per_row = atlas_width,
        .rows_per_layer = atlas_height,
    });
    const destination = std.mem.zeroInit(c.SDL_GPUTextureRegion, .{
        .texture = texture,
        .w = atlas_width,
        .h = atlas_height,
        .d = 1,
    });
    c.SDL_UploadToGPUTexture(pass, &source, &destination, false);
    c.SDL_EndGPUCopyPass(pass);
    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
        std.log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdl.lastError()});
        return error.SdlSubmit;
    }

    return texture;
}

