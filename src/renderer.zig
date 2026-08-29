const std = @import("std");
const builtin = @import("builtin");

/// main.zig takes its SDL types from here rather than running its own
/// `@cImport`: two blocks that differ by so much as whitespace generate two
/// unrelated sets of types, and a `*SDL_Window` from one will not pass as a
/// `*SDL_Window` to the other.
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const ft = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
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
/// the same pixels and there is no font-matching code to get wrong.
const font_data = @embedFile("DejaVuSans.ttf");

const font_pixel_size = 32;

/// Proportional advances put glyph origins on fractional pixels. Rasterising
/// each glyph at four horizontal offsets lets a quad stay pixel-aligned while
/// the origin it represents does not, which is what keeps stems from wobbling
/// as text reflows. Four is the usual stopping point: the atlas grows linearly
/// in this number and the difference past a quarter of a pixel is not visible.
const subpixel_positions = 4;

/// Printable ASCII, which is all the atlas holds until there is text to demand
/// more. Rasterising on first use is the same lookup with a slower miss path.
const first_char = ' ';
const last_char = '~';
const char_count = last_char - first_char + 1;

const atlas_width = 512;
const atlas_height = 512;

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

/// The font as the GPU sees it: coverage for every character the atlas holds, at
/// every subpixel offset, plus the metrics needed to place it.
///
/// Entries are keyed by `(character, subpixel)`, because two origins a quarter
/// of a pixel apart are genuinely different pictures, not the same picture
/// moved. That pair is the identity of a rasterised glyph.
const Font = struct {
    texture: *c.SDL_GPUTexture,
    glyphs: [char_count * subpixel_positions]Glyph,
    /// Unkerned, straight from the face. HarfBuzz replaces these with shaped
    /// advances, which is where contextual kerning comes from.
    advances: [char_count]f32,
    ascent: f32,
    line_height: f32,

    fn glyph(self: *const Font, char: u8, subpixel: usize) ?Glyph {
        if (char < first_char or char > last_char) return null;
        const found = self.glyphs[glyphIndex(char, subpixel)];
        // A space rasterises to nothing; there is no quad to draw for it.
        return if (found.width == 0) null else found;
    }

    fn advance(self: *const Font, char: u8) f32 {
        if (char < first_char or char > last_char) return 0;
        const index: usize = char - first_char;
        return self.advances[index];
    }
};

/// Where `(char, subpixel)` lives in `Font.glyphs`.
fn glyphIndex(char: u8, subpixel: usize) usize {
    // Widened before the multiply, which overflows a u8 long before the
    // character range runs out.
    const index: usize = char - first_char;
    return index * subpixel_positions + subpixel;
}

test "glyphIndex does not wrap for late characters" {
    try std.testing.expectEqual(@as(usize, 0), glyphIndex(first_char, 0));
    try std.testing.expectEqual(@as(usize, 260), glyphIndex('a', 0));
    try std.testing.expectEqual(
        @as(usize, char_count * subpixel_positions - 1),
        glyphIndex(last_char, subpixel_positions - 1),
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
    gpu: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    sampler: *c.SDL_GPUSampler,
    font: Font,

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

        const font = try buildFont(gpa, gpu);
        errdefer c.SDL_ReleaseGPUTexture(gpu, font.texture);

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
            .gpu = gpu,
            .window = window,
            .pipeline = pipeline,
            .sampler = sampler,
            .font = font,
        };
    }

    pub fn deinit(self: *Renderer) void {
        c.SDL_ReleaseGPUSampler(self.gpu, self.sampler);
        c.SDL_ReleaseGPUTexture(self.gpu, self.font.texture);
        c.SDL_ReleaseGPUGraphicsPipeline(self.gpu, self.pipeline);
        c.SDL_ReleaseWindowFromGPUDevice(self.gpu, self.window);
        c.SDL_DestroyGPUDevice(self.gpu);
    }

    pub fn present(self: *Renderer, lines: []const []const u8) !void {
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
        var baseline = 48 + self.font.ascent;
        for (lines) |line| {
            self.drawText(cmd, pass, line, 48, baseline, viewport);
            baseline += self.font.line_height;
        }

        c.SDL_EndGPURenderPass(pass);

        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
            std.log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdlError()});
            return error.SdlSubmit;
        }
    }

    /// Places each glyph of `text` along a baseline, advancing the pen by
    /// fractional amounts and snapping only the quad. Advances come from the
    /// face, so this is unkerned; shaping replaces the loop wholesale.
    fn drawText(
        self: *Renderer,
        cmd: *c.SDL_GPUCommandBuffer,
        pass: *c.SDL_GPURenderPass,
        text: []const u8,
        x: f32,
        baseline: f32,
        viewport: [2]f32,
    ) void {
        var pen = x;
        for (text) |char| {
            const position = quantize(pen);
            if (self.font.glyph(char, position.subpixel)) |g| {
                const quad: Quad = .{
                    .dest_origin = .{
                        position.pixel + @as(f32, @floatFromInt(g.left)),
                        @round(baseline) - @as(f32, @floatFromInt(g.top)),
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
            pen += self.font.advance(char);
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

/// Rasterises every character at every subpixel offset into one texture and
/// uploads it once. Rasterising is the expensive part of drawing a glyph and it
/// happens here, off the frame path, which is the point of having an atlas.
fn buildFont(gpa: std.mem.Allocator, gpu: *c.SDL_GPUDevice) !Font {
    const pixels = try gpa.alloc(u8, atlas_width * atlas_height);
    defer gpa.free(pixels);
    @memset(pixels, 0);

    var font: Font = .{
        .texture = undefined,
        .glyphs = @splat(.{}),
        .advances = @splat(0),
        .ascent = 0,
        .line_height = 0,
    };

    var library: ft.FT_Library = null;
    if (ft.FT_Init_FreeType(&library) != 0) {
        return error.FreetypeInit;
    }
    defer _ = ft.FT_Done_FreeType(library);

    // From memory, not from a path: the font is part of the binary.
    var face: ft.FT_Face = null;
    if (ft.FT_New_Memory_Face(library, font_data, font_data.len, 0, &face) != 0) {
        return error.FreetypeNewFace;
    }
    defer _ = ft.FT_Done_Face(face);

    if (ft.FT_Set_Pixel_Sizes(face, 0, font_pixel_size) != 0) {
        return error.FreetypeSetPixelSizes;
    }
    font.ascent = fromFixed(face.*.size.*.metrics.ascender);
    font.line_height = fromFixed(face.*.size.*.metrics.height);

    // A shelf packer: fill a row left to right, start a new row when the next
    // glyph will not fit. Glyphs at one pixel size are close enough in height
    // that the wasted strip above the short ones is not worth a better fit.
    var shelf_x: u16 = 0;
    var shelf_y: u16 = 0;
    var shelf_height: u16 = 0;

    for (first_char..last_char + 1) |char| {
        const index = char - first_char;
        for (0..subpixel_positions) |subpixel| {
            // FreeType translates the outline before rasterising, so the
            // fractional offset ends up in the coverage rather than being
            // approximated by moving the finished bitmap.
            var delta: ft.FT_Vector = .{
                .x = @intCast(subpixel * 64 / subpixel_positions),
                .y = 0,
            };
            ft.FT_Set_Transform(face, null, &delta);

            if (ft.FT_Load_Char(face, @intCast(char), ft.FT_LOAD_RENDER) != 0) {
                return error.FreetypeLoadChar;
            }
            const slot = face.*.glyph;
            font.advances[index] = fromFixed(slot.*.advance.x);

            const bitmap = slot.*.bitmap;
            if (bitmap.width == 0 or bitmap.rows == 0) continue;

            const width: u16 = @intCast(bitmap.width);
            const height: u16 = @intCast(bitmap.rows);
            if (shelf_x + width > atlas_width) {
                shelf_x = 0;
                shelf_y += shelf_height;
                shelf_height = 0;
            }
            if (shelf_y + height > atlas_height) return error.AtlasFull;

            // Rows sit `pitch` bytes apart, which is not `width`: FreeType pads
            // them, and copying the buffer whole would shear the glyph.
            const pitch: usize = @intCast(bitmap.pitch);
            for (0..height) |row| {
                const source = bitmap.buffer + row * pitch;
                const start = (shelf_y + row) * atlas_width + shelf_x;
                @memcpy(pixels[start..][0..width], source[0..width]);
            }

            font.glyphs[glyphIndex(@intCast(char), subpixel)] = .{
                .x = shelf_x,
                .y = shelf_y,
                .width = width,
                .height = height,
                .left = @intCast(slot.*.bitmap_left),
                .top = @intCast(slot.*.bitmap_top),
            };

            shelf_x += width;
            shelf_height = @max(shelf_height, height);
        }
    }

    font.texture = try uploadCoverage(gpu, pixels);
    return font;
}

/// FreeType reports most metrics in 26.6 fixed point: pixels times 64.
fn fromFixed(value: ft.FT_Pos) f32 {
    return @as(f32, @floatFromInt(value)) / 64.0;
}

fn uploadCoverage(gpu: *c.SDL_GPUDevice, pixels: []const u8) !*c.SDL_GPUTexture {
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

    const transfer = c.SDL_CreateGPUTransferBuffer(gpu, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @as(u32, @intCast(pixels.len)),
    })) orelse {
        std.log.err("SDL_CreateGPUTransferBuffer: {s}", .{sdlError()});
        return error.SdlCreateTransferBuffer;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(gpu, transfer);

    const mapped = c.SDL_MapGPUTransferBuffer(gpu, transfer, false) orelse {
        std.log.err("SDL_MapGPUTransferBuffer: {s}", .{sdlError()});
        return error.SdlMapTransferBuffer;
    };
    @memcpy(@as([*]u8, @ptrCast(mapped))[0..pixels.len], pixels);
    c.SDL_UnmapGPUTransferBuffer(gpu, transfer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(gpu) orelse {
        std.log.err("SDL_AcquireGPUCommandBuffer: {s}", .{sdlError()});
        return error.SdlAcquireCommandBuffer;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
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
    c.SDL_UploadToGPUTexture(copy_pass, &source, &destination, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
        std.log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdlError()});
        return error.SdlSubmit;
    }

    return texture;
}
