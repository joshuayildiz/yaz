//! Everything between a line of text and the pixels the GPU samples for it:
//! shaping the bytes into positioned glyph ids, rasterising the ones the atlas
//! does not hold yet, uploading those, and saying where to sample each from.
//!
//! Shaping and rasterising stay together because neither can be asked without
//! the other. Shaping decides which glyphs exist, so it is the only thing that
//! can say what to rasterise; rasterising decides where they land in the atlas,
//! so it is the only thing that can say what to sample.
//!
//! What is not here is which lines a document has and which of them have
//! changed. That belongs to the document rather than to a font: one atlas serves
//! every document, and each document caches its own shaped lines. See
//! document.zig.

const std = @import("std");
const builtin = @import("builtin");

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

/// Embedded rather than discovered, so every platform renders the same pixels.
/// Which file comes from config.zig, by way of the build.
const font_data = @embedFile("font");

/// Proportional advances put glyph origins on fractional pixels. Rasterising at
/// four horizontal offsets keeps the quad pixel-aligned while the origin is not,
/// which stops stems wobbling as text reflows. The atlas grows linearly in this
/// number and a quarter of a pixel is past where the difference shows.
const subpixel_positions = 4;

/// The atlas starts empty and fills as glyphs are asked for. Nothing else works
/// once text is shaped: `fi` is one glyph here and no character maps to it, so no
/// walk over characters would ever rasterise it.
///
/// Single-channel coverage, so it costs its area in bytes. A glyph rasterised at
/// twice the size takes four times the area, and every Mac SDL runs on is
/// Retina, so macOS is sized for a scale of two at build time. Elsewhere the
/// scale is whatever the display reports and 1024 covers a scale of one.
///
/// 46 distinct glyphs reach 82 rows, putting the ceiling near 500 -- past a page
/// of English, short of a CJK document, which wants eviction rather than a
/// bigger number here.
///
/// TODO: the ceiling follows scale, not platform. Windows on a 4K panel at 200%
/// is as dense as a Mac and gets the smaller atlas.
const atlas_width = switch (builtin.target.os.tag) {
    .macos, .ios, .tvos, .watchos => 2048,
    else => 1024,
};
const atlas_height = atlas_width;

/// A slot is an atlased glyph and its `subpixel_positions` variants. The cap
/// keeps the metrics one flat array, and is deliberately past what the texture
/// holds so that running out of texture is the limit that bites.
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

/// Where the quad goes and where to sample it from, both in whole pixels: the
/// fraction of the pen position chose the subpixel variant instead.
///
/// `extern` because the array is copied to the GPU as it stands, so the field
/// order is the struct declared in the shader. renderer.zig tests that.
pub const Sprite = extern struct {
    dest: [2]f32,
    source: [2]f32,
    size: [2]f32,

    /// A quad for the pipeline that samples nothing, so `source` means nothing
    /// either. Any size: this is what the caret and the scrollbar are.
    pub fn solid(dest: [2]f32, extent: [2]f32) Sprite {
        return .{ .dest = dest, .source = .{ 0, 0 }, .size = extent };
    }
};

/// One per cluster boundary shaping reported, plus one past the last glyph.
///
/// Boundaries rather than characters: `ffi` is one glyph over three bytes with
/// nowhere between them for a caret, and a space is a boundary with no glyph at
/// all. Neither is recoverable from the sprites, so this is kept, not derived.
pub const Caret = struct {
    /// Bytes from the start of the line.
    offset: u32,

    /// Unrounded: this is a measurement, and rounding would make two boundaries
    /// a third of a pixel apart into the same one.
    x: f32,
};

/// Held in the line's own coordinates: x from where the line starts, y from its
/// baseline. Knowing nothing about where the line sits on screen is what lets a
/// line that only moved down keep its layout.
pub const LineLayout = struct {
    sprites: std.ArrayList(Sprite) = .empty,

    /// Where the caret may go on this line, kept because it comes out of the
    /// same shaping pass the sprites do and costs nothing extra to record.
    carets: std.ArrayList(Caret) = .empty,

    /// What this was shaped from. A cache that has drifted out of step with the
    /// document would otherwise draw the wrong line rather than say so.
    bytes: usize = 0,

    shaped: bool = false,

    pub fn deinit(self: *LineLayout, allocator: std.mem.Allocator) void {
        self.sprites.deinit(allocator);
        self.carets.deinit(allocator);
    }
};

/// The atlas texture's dimensions, which the vertex shader needs to turn a
/// source rectangle into texture coordinates.
pub const size: [2]f32 = .{ atlas_width, atlas_height };

/// The font as the GPU sees it: coverage for the glyphs asked for so far, at
/// every subpixel offset, plus the metrics to place them.
///
/// Keyed by `(glyph id, subpixel)`, because two origins a quarter of a pixel
/// apart are different pictures rather than one picture moved.
///
/// FreeType stays open for the life of the font: there is no moment when the
/// atlas is finished, since a glyph nobody has typed is not rasterised yet.
pub const GlyphAtlas = struct {
    allocator: std.mem.Allocator,
    gpu: *c.SDL_GPUDevice,
    library: ft.FT_Library,
    face: ft.FT_Face,
    texture: *c.SDL_GPUTexture,
    shaper: Shaper,

    /// Glyph id to a slot in `glyphs`. One entry per glyph in the font, which is
    /// kilobytes, so the lookup is an index rather than a hash.
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

    /// What everything above was built at, so a move to a display of a
    /// different density is a float compare rather than the right event.
    scale: f32,

    const Placed = struct { x: u16, y: u16 };

    const Upload = struct {
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        offset: u32,
    };

    pub fn init(allocator: std.mem.Allocator, gpu: *c.SDL_GPUDevice, scale: f32) !GlyphAtlas {
        var library: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&library) != 0) return error.FreetypeInit;
        errdefer _ = ft.FT_Done_FreeType(library);

        // From memory, not from a path: the font is part of the binary.
        var face: ft.FT_Face = null;
        if (ft.FT_New_Memory_Face(library, font_data, font_data.len, 0, &face) != 0) {
            return error.FreetypeNewFace;
        }
        errdefer _ = ft.FT_Done_Face(face);

        if (ft.FT_Set_Pixel_Sizes(face, 0, pixelSize(scale)) != 0) {
            return error.FreetypeSetPixelSizes;
        }

        const slots = try allocator.alloc(u16, @intCast(face.*.num_glyphs));
        errdefer allocator.free(slots);
        @memset(slots, no_slot);

        const glyphs = try allocator.alloc(Glyph, max_slots * subpixel_positions);
        errdefer allocator.free(glyphs);

        var shaper = try Shaper.init(scale);
        errdefer shaper.deinit();

        return .{
            .allocator = allocator,
            .gpu = gpu,
            .library = library,
            .face = face,
            .texture = try createAtlas(allocator, gpu),
            .shaper = shaper,
            .slots = slots,
            .glyphs = glyphs,
            .ascent = fromFixed(face.*.size.*.metrics.ascender),
            .line_height = fromFixed(face.*.size.*.metrics.height),
            .scale = scale,
        };
    }

    /// Rebuilds the atlas at a new display scale, answering whether it had to.
    /// A window dragged to a display of a different density lands here.
    ///
    /// The texture survives, since its size does not depend on the scale; what
    /// a rebuild costs is the packing state and the metrics. The next layout
    /// refills it through the path a first redraw uses.
    ///
    /// Callers holding a shaped line have to drop it. `TextView` does.
    pub fn setScale(self: *GlyphAtlas, scale: f32) !bool {
        if (scale == self.scale) return false;

        if (ft.FT_Set_Pixel_Sizes(self.face, 0, pixelSize(scale)) != 0) {
            return error.FreetypeSetPixelSizes;
        }
        self.shaper.setScale(scale);
        self.ascent = fromFixed(self.face.*.size.*.metrics.ascender);
        self.line_height = fromFixed(self.face.*.size.*.metrics.height);
        self.scale = scale;

        @memset(self.slots, no_slot);
        self.used = 0;
        self.shelf_x = 0;
        self.shelf_y = 0;
        self.shelf_height = 0;

        // Queued coverage is for positions the packer is about to hand out
        // again. Uploading it would paint the old glyphs over the new ones.
        self.staging.clearRetainingCapacity();
        self.uploads.clearRetainingCapacity();

        return true;
    }

    pub fn deinit(self: *GlyphAtlas) void {
        c.SDL_ReleaseGPUTexture(self.gpu, self.texture);
        self.shaper.deinit();
        self.uploads.deinit(self.allocator);
        self.staging.deinit(self.allocator);
        self.allocator.free(self.glyphs);
        self.allocator.free(self.slots);
        _ = ft.FT_Done_Face(self.face);
        _ = ft.FT_Done_FreeType(self.library);
    }

    /// Into the line's own coordinates: x from where it starts, y from its
    /// baseline. Knowing nothing about the screen is what lets the caller keep
    /// the answer.
    pub fn shapeLine(self: *GlyphAtlas, text: []const u8, entry: *LineLayout) !void {
        entry.sprites.clearRetainingCapacity();
        entry.carets.clearRetainingCapacity();

        const shaped = self.shaper.shape(text);
        var pen: f32 = 0;
        for (shaped.infos, shaped.positions) |info, offset| {
            try self.request(info.codepoint);

            // Clusters only climb, so the last entry is the only possible
            // repeat. Glyphs sharing one -- a letter and its mark -- are a
            // single boundary at the pen before the first.
            if (entry.carets.items.len == 0 or entry.carets.getLast().offset != info.cluster) {
                try entry.carets.append(self.allocator, .{ .offset = info.cluster, .x = pen });
            }

            // Moves a glyph off the pen without moving the pen, which is how
            // marks land on their letters. Latin leaves it at zero.
            const position = quantize(pen + fromFixed(offset.x_offset));
            pen += fromFixed(offset.x_advance);

            // A space contributes its advance and nothing to draw.
            const g = self.glyph(info.codepoint, position.subpixel) orelse continue;
            try entry.sprites.append(self.allocator, .{
                .dest = .{
                    position.pixel + @as(f32, @floatFromInt(g.left)),
                    -@round(fromFixed(offset.y_offset)) - @as(f32, @floatFromInt(g.top)),
                },
                .source = .{ @floatFromInt(g.x), @floatFromInt(g.y) },
                .size = .{ @floatFromInt(g.width), @floatFromInt(g.height) },
            });
        }

        // No glyph begins at the end of the line, so the caret can only go
        // there by being appended.
        try entry.carets.append(self.allocator, .{ .offset = @intCast(text.len), .x = pen });

        entry.bytes = text.len;
        entry.shaped = true;
    }

    /// Rasterises `id` the first time it is asked for. Runs once per glyph laid
    /// out, so after a line's first redraw every call is a load and a compare.
    fn request(self: *GlyphAtlas, id: u32) !void {
        // Not a glyph this face defines, or already decided one way or another.
        if (id >= self.slots.len or self.slots[id] != no_slot) return;

        // `max_slots` is past what the texture holds, so this should be
        // unreachable before `pack` fails.
        if (self.used == max_slots) {
            std.debug.panic("glyph atlas is out of slots at {d}, asked for glyph {d}", .{ max_slots, id });
        }

        const slot = self.used;
        for (0..subpixel_positions) |subpixel| {
            // Translating the outline puts the fractional offset in the
            // coverage rather than approximating it by moving the bitmap.
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
            // TODO: fixed size and no eviction, so a document with more
            // distinct glyphs than fit lands here -- CJK long before Latin.
            // Growing at runtime means a larger texture, re-running the packer
            // over `slots` and re-rasterising; FreeType is still open, so no CPU
            // copy of the atlas has to be kept for it.
            const placed = self.pack(width, height) orelse std.debug.panic(
                "glyph atlas is full: no room for glyph {d} at {d}x{d} in {d}x{d}, {d} glyphs in",
                .{ id, width, height, atlas_width, atlas_height, self.used },
            );

            // FreeType pads rows to `pitch`, so copying the buffer whole would
            // shear the glyph. What goes to the GPU is tight.
            const offset: u32 = @intCast(self.staging.items.len);
            const pitch: usize = @intCast(bitmap.pitch);
            try self.staging.ensureUnusedCapacity(self.allocator, @as(usize, width) * height);
            for (0..height) |row| {
                self.staging.appendSliceAssumeCapacity((bitmap.buffer + row * pitch)[0..width]);
            }
            try self.uploads.append(self.allocator, .{
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

    /// Sends everything rasterised since the last call. The early return is
    /// what keeps a steady-state frame free of transfers.
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
            // wants 256-byte padding, and the pinned shader format means SDL
            // never selects it.
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
        // Laying a glyph out requests it, and a failed request panicked there.
        std.debug.assert(id < self.slots.len);
        const slot = self.slots[id];
        std.debug.assert(slot != no_slot);

        const found = self.glyphs[glyphIndex(slot, subpixel)];
        // A space rasterises to nothing; there is no quad to draw for it.
        return if (found.width == 0) null else found;
    }
};

/// Where `(slot, subpixel)` lives in `GlyphAtlas.glyphs`.
fn glyphIndex(slot: u16, subpixel: usize) usize {
    // Widened before the multiply, which overflows a u16 well inside the slot
    // counts the atlas can hold.
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

/// Splits a pen position into the pixel the quad lands on and the variant to
/// sample. Rounding rather than truncating: 0.24 of a pixel along is nearer the
/// quarter-pixel rasterisation than the whole-pixel one.
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

/// Turns bytes into glyph ids and the positions to draw them at. Proportional
/// text cannot do without it: advances differ per character and kerning depends
/// on which are adjacent, so a pen position is accumulated, never computed.
///
/// HarfBuzz reads the font tables directly rather than going through `hb-ft`,
/// which would report advances rounded to whole pixels once hinting is on --
/// exactly the fraction the subpixel atlas exists to render. Glyph ids agree
/// either way, being a property of the file.
const Shaper = struct {
    font: *hb.hb_font_t,
    /// Reused across lines: shaping is on the path from keystroke to redraw,
    /// and this is the allocation it would otherwise make every time.
    buffer: *hb.hb_buffer_t,

    fn init(scale: f32) !Shaper {
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
        setFontScale(font, scale);

        const buffer = hb.hb_buffer_create() orelse return error.HarfbuzzCreateBuffer;
        return .{ .font = font, .buffer = buffer };
    }

    /// Nothing is cached across calls, so this is the whole of a resize.
    fn setScale(self: *Shaper, scale: f32) void {
        setFontScale(self.font, scale);
    }

    /// Font units until told otherwise. Scaling by 64 asks for 26.6 fixed point,
    /// which is what FreeType reports metrics in, so the two halves agree without
    /// a conversion. Both must be told the same size.
    fn setFontScale(font: *hb.hb_font_t, scale: f32) void {
        const px: c_int = @intCast(pixelSize(scale));
        hb.hb_font_set_scale(font, px * 64, px * 64);
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

        // Left to right by decision: there is no bidi pass and there is not
        // going to be one, so right-to-left text shapes its joining forms
        // correctly and is then set down backwards.
        //
        // Stated rather than guessed, because `hb_buffer_guess_segment_properties`
        // takes the language from the system locale and the point of embedding
        // the font is that every machine draws the same pixels. See README.md
        // for what the script tag costs, which with this font is nothing.
        hb.hb_buffer_set_direction(self.buffer, hb.HB_DIRECTION_LTR);
        hb.hb_buffer_set_script(self.buffer, hb.HB_SCRIPT_LATIN);
        hb.hb_buffer_set_language(self.buffer, hb.hb_language_from_string("en", -1));

        hb.hb_shape(self.font, self.buffer, null, 0);

        var count: c_uint = 0;
        const infos = hb.hb_buffer_get_glyph_infos(self.buffer, &count);
        const positions = hb.hb_buffer_get_glyph_positions(self.buffer, &count);

        // HarfBuzz answers an empty buffer with a null pointer rather than a
        // pointer to no glyphs, and slicing null is not an empty slice. Every
        // file ending in a newline has such a line.
        if (count == 0) return .{ .infos = &.{}, .positions = &.{} };

        return .{ .infos = infos[0..count], .positions = positions[0..count] };
    }
};

/// How wide a run shapes to. Only the tests want a total; hit-testing needs the
/// width at each cluster and gets it from `shapeLine`.
fn shapedWidth(shaper: *Shaper, text: []const u8) f32 {
    var total: f32 = 0;
    for (shaper.shape(text).positions) |position| total += fromFixed(position.x_advance);
    return total;
}

test "shaping kerns a pair that plain advances would set too far apart" {
    var shaper = try Shaper.init(1);
    defer shaper.deinit();

    // Nothing but the kerning table makes the pair narrower than the letters
    // measured alone, and every other test here would pass without it.
    const together = shapedWidth(&shaper, "AV");
    const apart = shapedWidth(&shaper, "A") + shapedWidth(&shaper, "V");
    try std.testing.expect(together < apart);
}

test "shaping returns one glyph per character for unkerned Latin" {
    var shaper = try Shaper.init(1);
    defer shaper.deinit();

    const text = "quick";
    const shaped = shaper.shape(text);
    try std.testing.expectEqual(text.len, shaped.infos.len);
    // Cluster values are byte offsets into the text, which is what cursor
    // positions will eventually be compared against.
    for (shaped.infos, 0..) |info, i| try std.testing.expectEqual(@as(u32, @intCast(i)), info.cluster);
}

test "a ligature's characters share one cluster" {
    var shaper = try Shaper.init(1);
    defer shaper.deinit();

    // "office" is six characters and four glyphs: f, f and i become one.
    const shaped = shaper.shape("office");
    try std.testing.expectEqual(4, shaped.infos.len);

    // Why the caret search works on boundaries rather than characters: the
    // ligature reports the offset of its first character, so 2 and 3 appear
    // nowhere here.
    var clusters: [4]u32 = undefined;
    for (shaped.infos, &clusters) |info, *cluster| cluster.* = info.cluster;
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 4, 5 }, &clusters);
}

test "an empty line shapes to no glyphs rather than crashing" {
    var shaper = try Shaper.init(1);
    defer shaper.deinit();

    // Reachable from a keystroke -- Return at the end of the document -- and
    // from opening any file that ends in a newline.
    const shaped = shaper.shape("");
    try std.testing.expectEqual(@as(usize, 0), shaped.infos.len);
    try std.testing.expectEqual(@as(usize, 0), shaped.positions.len);
}

test "shaping follows a change of scale" {
    var shaper = try Shaper.init(1);
    defer shaper.deinit();

    // The half of a rescale that is easy to leave out: resize the face and not
    // the shaper, and pen positions are computed at one size for glyphs
    // rasterised at another. That reads as bad tracking rather than as a bug.
    const single = shapedWidth(&shaper, "quick");
    shaper.setScale(2);
    const double = shapedWidth(&shaper, "quick");

    // Not exactly twice: advances land on 26.6 fixed point, so each glyph may
    // round by a sixty-fourth.
    try std.testing.expectApproxEqAbs(single * 2, double, 0.5);
}

/// What FreeType and HarfBuzz are both set to. Whole pixels, because that is the
/// unit FreeType takes; the fraction of a *pen position* is a different question,
/// and what the subpixel variants are for.
fn pixelSize(scale: f32) u32 {
    const px = @round(@as(f32, config.font_size) * scale);
    // A zero-pixel face makes FreeType fail somewhere less obvious.
    std.debug.assert(px >= 1);
    return @intFromFloat(px);
}

test "pixelSize scales the nominal size" {
    try std.testing.expectEqual(@as(u32, config.font_size), pixelSize(1));
    try std.testing.expectEqual(@as(u32, config.font_size * 2), pixelSize(2));
}

test "pixelSize rounds rather than truncating" {
    // A property rather than worked answers, which would tie this to
    // config.font_size -- a knob, and one that has already moved once.
    const nominal: f32 = config.font_size;
    var scale: f32 = 1;
    while (scale <= 3) : (scale += 0.25) {
        const px: f32 = @floatFromInt(pixelSize(scale));
        // Truncating can be a whole pixel out; rounding never is.
        try std.testing.expect(@abs(px - nominal * scale) <= 0.5);
    }
}

/// FreeType reports most metrics in 26.6 fixed point: pixels times 64. So does
/// HarfBuzz, once its font is scaled to match, hence the two integer types.
fn fromFixed(value: anytype) f32 {
    return @as(f32, @floatFromInt(value)) / 64.0;
}

/// Creates the atlas texture and zeroes it. Nothing samples outside a glyph's
/// own rectangle, so the clear is not load-bearing today; it costs one upload at
/// startup and means the texture never holds anything nobody wrote.
fn createAtlas(allocator: std.mem.Allocator, gpu: *c.SDL_GPUDevice) !*c.SDL_GPUTexture {
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

    const blank = try allocator.alloc(u8, atlas_width * atlas_height);
    defer allocator.free(blank);
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
