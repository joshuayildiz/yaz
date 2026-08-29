const std = @import("std");
const builtin = @import("builtin");

/// main.zig takes its SDL types from here rather than running its own
/// `@cImport`: two blocks that differ by so much as whitespace generate two
/// unrelated sets of types, and a `*SDL_Window` from one will not pass as a
/// `*SDL_Window` to the other.
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const config = @import("./config.zig");

const ft = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

const hb = @cImport({
    @cInclude("hb.h");
});

/// The build compiles shaders to exactly one bytecode format, chosen from the
/// target. Declaring it here rather than probing at runtime also pins the
/// backend: SDL can only pick one that accepts this format, so Windows gets
/// Vulkan rather than whichever backend SDL would have preferred.
/// Keep in step with `shaderFormat` in build.zig.
const shader_target: struct {
    format: c.SDL_GPUShaderFormat,
    entrypoint: [*:0]const u8,
} = switch (builtin.target.os.tag) {
    .macos, .ios, .tvos, .watchos => .{ .format = c.SDL_GPU_SHADERFORMAT_MSL, .entrypoint = "main0" },
    else => .{ .format = c.SDL_GPU_SHADERFORMAT_SPIRV, .entrypoint = "main" },
};

const vertex_shader_code = @embedFile("quad.vert");
const fragment_shader_code = @embedFile("quad.frag");

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

/// `Font.slots` holds one of these per glyph the font defines, so most entries
/// stay `no_slot` forever.
const no_slot = std.math.maxInt(u16);
/// Asked for, and it cannot be atlased: no room left, or FreeType refused it.
/// Distinct from `no_slot` so the failure is not retried on every redraw.
const slot_unavailable = no_slot - 1;

/// SDL reports failures out of band; this is only meaningful right after one.
pub fn sdlError() []const u8 {
    return std.mem.span(c.SDL_GetError());
}

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
const Font = struct {
    gpa: std.mem.Allocator,
    library: ft.FT_Library,
    face: ft.FT_Face,
    texture: *c.SDL_GPUTexture,

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

    fn init(gpa: std.mem.Allocator, gpu: *c.SDL_GPUDevice) !Font {
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

        return .{
            .gpa = gpa,
            .library = library,
            .face = face,
            .texture = try createAtlas(gpa, gpu),
            .slots = slots,
            .glyphs = glyphs,
            .ascent = fromFixed(face.*.size.*.metrics.ascender),
            .line_height = fromFixed(face.*.size.*.metrics.height),
        };
    }

    fn deinit(self: *Font) void {
        self.uploads.deinit(self.gpa);
        self.staging.deinit(self.gpa);
        self.gpa.free(self.glyphs);
        self.gpa.free(self.slots);
        _ = ft.FT_Done_Face(self.face);
        _ = ft.FT_Done_FreeType(self.library);
    }

    /// Rasterises `id` if this is the first time it has been asked for. Both the
    /// expensive path and the do-nothing path go through here, once per glyph
    /// laid out; after a line's first redraw every call is a load and a compare.
    fn request(self: *Font, id: u32) !void {
        // Not a glyph this face defines, or already decided one way or another.
        if (id >= self.slots.len or self.slots[id] != no_slot) return;

        if (self.used == max_slots) {
            std.log.warn("atlas is out of slots; glyph {d} will not draw", .{id});
            self.slots[id] = slot_unavailable;
            return;
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
                std.log.warn("FreeType cannot render glyph {d}", .{id});
                self.slots[id] = slot_unavailable;
                return;
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
            const placed = self.pack(width, height) orelse {
                std.log.warn("atlas is full; glyph {d} will not draw", .{id});
                self.slots[id] = slot_unavailable;
                return;
            };

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
    fn pack(self: *Font, width: u16, height: u16) ?Placed {
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
    fn flush(self: *Font, gpu: *c.SDL_GPUDevice) !void {
        if (self.uploads.items.len == 0) return;
        defer {
            self.uploads.clearRetainingCapacity();
            self.staging.clearRetainingCapacity();
        }

        const transfer = c.SDL_CreateGPUTransferBuffer(gpu, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = @as(u32, @intCast(self.staging.items.len)),
        })) orelse {
            std.log.err("SDL_CreateGPUTransferBuffer: {s}", .{sdlError()});
            return error.SdlCreateTransferBuffer;
        };
        defer c.SDL_ReleaseGPUTransferBuffer(gpu, transfer);

        const mapped = c.SDL_MapGPUTransferBuffer(gpu, transfer, false) orelse {
            std.log.err("SDL_MapGPUTransferBuffer: {s}", .{sdlError()});
            return error.SdlMapTransferBuffer;
        };
        @memcpy(@as([*]u8, @ptrCast(mapped))[0..self.staging.items.len], self.staging.items);
        c.SDL_UnmapGPUTransferBuffer(gpu, transfer);

        const cmd = c.SDL_AcquireGPUCommandBuffer(gpu) orelse {
            std.log.err("SDL_AcquireGPUCommandBuffer: {s}", .{sdlError()});
            return error.SdlAcquireCommandBuffer;
        };
        const pass = c.SDL_BeginGPUCopyPass(cmd);
        for (self.uploads.items) |upload| {
            // Tight rows, which Vulkan and Metal both take as given. D3D12
            // would want them padded to 256 bytes, and the shader format the
            // build pins means SDL never selects it.
            const source = std.mem.zeroInit(c.SDL_GPUTextureTransferInfo, .{
                .transfer_buffer = transfer,
                .offset = upload.offset,
                .pixels_per_row = @as(u32, upload.width),
                .rows_per_layer = @as(u32, upload.height),
            });
            const destination = std.mem.zeroInit(c.SDL_GPUTextureRegion, .{
                .texture = self.texture,
                .x = @as(u32, upload.x),
                .y = @as(u32, upload.y),
                .w = @as(u32, upload.width),
                .h = @as(u32, upload.height),
                .d = 1,
            });
            c.SDL_UploadToGPUTexture(pass, &source, &destination, false);
        }
        c.SDL_EndGPUCopyPass(pass);

        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
            std.log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdlError()});
            return error.SdlSubmit;
        }
    }

    fn glyph(self: *const Font, id: u32, subpixel: usize) ?Glyph {
        if (id >= self.slots.len) return null;
        const slot = self.slots[id];
        if (slot == no_slot or slot == slot_unavailable) return null;
        const found = self.glyphs[glyphIndex(slot, subpixel)];
        // A space rasterises to nothing; there is no quad to draw for it.
        return if (found.width == 0) null else found;
    }
};

/// Where `(slot, subpixel)` lives in `Font.glyphs`.
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

/// Matches the uniform block in quad.vert.glsl. Every field is a vec2, which
/// has the same size and alignment in std140 as it does here.
const Quad = extern struct {
    dest_origin: [2]f32,
    dest_size: [2]f32,
    source_origin: [2]f32,
    source_size: [2]f32,
    viewport: [2]f32,
    atlas_size: [2]f32,
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    gpu: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    sampler: *c.SDL_GPUSampler,
    font: Font,
    shaper: Shaper,
    /// Where every glyph of the current frame goes. Cleared rather than freed
    /// between frames: it settles at the size of a screenful and stops
    /// allocating, which is what keeps a redraw free of the allocator.
    layout: std.ArrayList(Placement) = .empty,

    /// One glyph, positioned. `x` and `baseline` are still fractional here;
    /// snapping them is the drawing step's business.
    const Placement = struct {
        id: u32,
        x: f32,
        baseline: f32,
    };

    /// Creates the device as well: the shader format the build compiled for
    /// decides which backend SDL is able to pick, so the choice belongs with
    /// the shaders rather than with the caller.
    pub fn init(gpa: std.mem.Allocator, window: *c.SDL_Window) !Renderer {
        const gpu = c.SDL_CreateGPUDevice(shader_target.format, false, null) orelse {
            std.log.err("SDL_CreateGPUDevice: {s}", .{sdlError()});
            return error.SdlCreateGpuDevice;
        };
        errdefer c.SDL_DestroyGPUDevice(gpu);

        if (!c.SDL_ClaimWindowForGPUDevice(gpu, window)) {
            std.log.err("SDL_ClaimWindowForGPUDevice: {s}", .{sdlError()});
            return error.SdlClaimWindow;
        }
        errdefer c.SDL_ReleaseWindowFromGPUDevice(gpu, window);

        const device_name = c.SDL_GetStringProperty(
            c.SDL_GetGPUDeviceProperties(gpu),
            c.SDL_PROP_GPU_DEVICE_NAME_STRING,
            "unknown",
        );
        std.log.info("gpu backend: {s} on {s}", .{
            std.mem.span(c.SDL_GetGPUDeviceDriver(gpu)),
            std.mem.span(device_name),
        });

        const pipeline = try createPipeline(gpu, window);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(gpu, pipeline);

        var font = try Font.init(gpa, gpu);
        errdefer c.SDL_ReleaseGPUTexture(gpu, font.texture);
        errdefer font.deinit();

        var shaper = try Shaper.init();
        errdefer shaper.deinit();

        // Nearest, not linear: quads are placed on whole pixels and sized to
        // match their source, so every sample lands dead centre on a texel and
        // interpolation has nothing to do but soften what it touches.
        const sampler = c.SDL_CreateGPUSampler(gpu, &std.mem.zeroInit(c.SDL_GPUSamplerCreateInfo, .{
            .min_filter = c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = c.SDL_GPU_FILTER_NEAREST,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        })) orelse {
            std.log.err("SDL_CreateGPUSampler: {s}", .{sdlError()});
            return error.SdlCreateSampler;
        };

        return .{
            .gpa = gpa,
            .gpu = gpu,
            .window = window,
            .pipeline = pipeline,
            .sampler = sampler,
            .font = font,
            .shaper = shaper,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.layout.deinit(self.gpa);
        self.shaper.deinit();
        self.font.deinit();
        c.SDL_ReleaseGPUSampler(self.gpu, self.sampler);
        c.SDL_ReleaseGPUTexture(self.gpu, self.font.texture);
        c.SDL_ReleaseGPUGraphicsPipeline(self.gpu, self.pipeline);
        c.SDL_ReleaseWindowFromGPUDevice(self.gpu, self.window);
        c.SDL_DestroyGPUDevice(self.gpu);
    }

    pub fn present(self: *Renderer, lines: []const []const u8) !void {
        // Everything that can be done without the GPU happens first. Shaping
        // decides which glyphs exist, rasterising the ones the atlas is missing
        // is a copy pass, and a copy pass cannot be opened inside a render pass.
        // Doing it before the swapchain is acquired also keeps this work out of
        // the window between waiting for a frame and handing one back.
        self.layout.clearRetainingCapacity();
        var pen_y = 48 + self.font.ascent;
        for (lines) |line| {
            try self.layoutLine(line, 48, pen_y);
            pen_y += self.font.line_height;
        }
        try self.font.flush(self.gpu);

        const cmd = c.SDL_AcquireGPUCommandBuffer(self.gpu) orelse {
            std.log.err("SDL_AcquireGPUCommandBuffer: {s}", .{sdlError()});
            return error.SdlAcquireCommandBuffer;
        };

        var swapchain: ?*c.SDL_GPUTexture = null;
        var width: u32 = 0;
        var height: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, self.window, &swapchain, &width, &height)) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            std.log.err("SDL_WaitAndAcquireGPUSwapchainTexture: {s}", .{sdlError()});
            return error.SdlAcquireSwapchain;
        }

        // No texture without an error means the window is minimised; nothing to draw.
        if (swapchain == null) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return;
        }

        const target = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
            .texture = swapchain,
            .clear_color = c.SDL_FColor{ .r = 0.07, .g = 0.07, .b = 0.08, .a = 1.0 },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
        });

        const pass = c.SDL_BeginGPURenderPass(cmd, &target, 1, null) orelse {
            std.log.err("SDL_BeginGPURenderPass: {s}", .{sdlError()});
            return error.SdlBeginRenderPass;
        };
        c.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);
        const binding = std.mem.zeroInit(c.SDL_GPUTextureSamplerBinding, .{
            .texture = self.font.texture,
            .sampler = self.sampler,
        });
        c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);

        const viewport: [2]f32 = .{ @floatFromInt(width), @floatFromInt(height) };
        self.draw(cmd, pass, viewport);

        c.SDL_EndGPURenderPass(pass);

        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
            std.log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdlError()});
            return error.SdlSubmit;
        }
    }

    /// Shapes one line and records where each of its glyphs goes, asking the
    /// atlas for anything it does not already hold.
    ///
    /// This runs on every redraw, which is more often than it needs to: a
    /// line's layout only changes when the line does. Step 12's cache is what
    /// makes that true, and until typing exists there is nothing to invalidate
    /// it against.
    fn layoutLine(self: *Renderer, text: []const u8, x: f32, baseline: f32) !void {
        const shaped = self.shaper.shape(text);

        var pen = x;
        for (shaped.infos, shaped.positions) |info, offset| {
            // The offset moves a glyph off the pen without moving the pen,
            // which is how marks land on the letters they belong to. Latin
            // leaves it at zero; something else will not.
            try self.layout.append(self.gpa, .{
                .id = info.codepoint,
                .x = pen + fromFixed(offset.x_offset),
                .baseline = baseline - fromFixed(offset.y_offset),
            });
            try self.font.request(info.codepoint);
            pen += fromFixed(offset.x_advance);
        }
    }

    /// One quad per glyph, each snapped to whole pixels while the origin it
    /// stands for is not: the subpixel variant carries the fraction.
    fn draw(
        self: *Renderer,
        cmd: *c.SDL_GPUCommandBuffer,
        pass: *c.SDL_GPURenderPass,
        viewport: [2]f32,
    ) void {
        for (self.layout.items) |placement| {
            const position = quantize(placement.x);
            const g = self.font.glyph(placement.id, position.subpixel) orelse continue;
            const quad: Quad = .{
                .dest_origin = .{
                    position.pixel + @as(f32, @floatFromInt(g.left)),
                    @round(placement.baseline) - @as(f32, @floatFromInt(g.top)),
                },
                .dest_size = .{ @floatFromInt(g.width), @floatFromInt(g.height) },
                .source_origin = .{ @floatFromInt(g.x), @floatFromInt(g.y) },
                .source_size = .{ @floatFromInt(g.width), @floatFromInt(g.height) },
                .viewport = viewport,
                .atlas_size = .{ atlas_width, atlas_height },
            };
            c.SDL_PushGPUVertexUniformData(cmd, 0, &quad, @sizeOf(Quad));
            c.SDL_DrawGPUPrimitives(pass, 4, 1, 0, 0);
        }
    }
};

fn createShader(
    gpu: *c.SDL_GPUDevice,
    stage: c.SDL_GPUShaderStage,
    num_samplers: u32,
    num_uniform_buffers: u32,
    code: []const u8,
) !*c.SDL_GPUShader {
    return c.SDL_CreateGPUShader(gpu, &std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, .{
        .code = code.ptr,
        .code_size = code.len,
        .entrypoint = shader_target.entrypoint,
        .format = shader_target.format,
        .stage = stage,
        .num_samplers = num_samplers,
        .num_uniform_buffers = num_uniform_buffers,
    })) orelse {
        std.log.err("SDL_CreateGPUShader: {s}", .{sdlError()});
        return error.SdlCreateShader;
    };
}

fn createPipeline(gpu: *c.SDL_GPUDevice, window: *c.SDL_Window) !*c.SDL_GPUGraphicsPipeline {
    const vertex = try createShader(gpu, c.SDL_GPU_SHADERSTAGE_VERTEX, 0, 1, vertex_shader_code);
    defer c.SDL_ReleaseGPUShader(gpu, vertex);

    const fragment = try createShader(gpu, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 1, 0, fragment_shader_code);
    defer c.SDL_ReleaseGPUShader(gpu, fragment);

    const color_target = std.mem.zeroInit(c.SDL_GPUColorTargetDescription, .{
        .format = c.SDL_GetGPUSwapchainTextureFormat(gpu, window),
        // Coverage arrives as alpha, so glyphs have to blend rather than
        // overwrite; a quad is a bounding box and most of it is empty.
        .blend_state = std.mem.zeroInit(c.SDL_GPUColorTargetBlendState, .{
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .enable_blend = true,
        }),
    });

    return c.SDL_CreateGPUGraphicsPipeline(gpu, &std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
        .vertex_shader = vertex,
        .fragment_shader = fragment,
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLESTRIP,
        .target_info = std.mem.zeroInit(c.SDL_GPUGraphicsPipelineTargetInfo, .{
            .color_target_descriptions = &color_target,
            .num_color_targets = 1,
        }),
    })) orelse {
        std.log.err("SDL_CreateGPUGraphicsPipeline: {s}", .{sdlError()});
        return error.SdlCreatePipeline;
    };
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
        std.log.err("SDL_CreateGPUTexture: {s}", .{sdlError()});
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
        std.log.err("SDL_CreateGPUTransferBuffer: {s}", .{sdlError()});
        return error.SdlCreateTransferBuffer;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(gpu, transfer);

    const mapped = c.SDL_MapGPUTransferBuffer(gpu, transfer, false) orelse {
        std.log.err("SDL_MapGPUTransferBuffer: {s}", .{sdlError()});
        return error.SdlMapTransferBuffer;
    };
    @memcpy(@as([*]u8, @ptrCast(mapped))[0..blank.len], blank);
    c.SDL_UnmapGPUTransferBuffer(gpu, transfer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(gpu) orelse {
        std.log.err("SDL_AcquireGPUCommandBuffer: {s}", .{sdlError()});
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
        std.log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdlError()});
        return error.SdlSubmit;
    }

    return texture;
}
