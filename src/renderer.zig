const std = @import("std");
const builtin = @import("builtin");

const sdl = @import("./sdl.zig");
const c = sdl.c;

const config = @import("./config.zig");

const painter_mod = @import("./painter.zig");
const Painter = painter_mod.Painter;
const Run = painter_mod.Run;

const glyph_atlas = @import("./glyph_atlas.zig");
const GlyphAtlas = glyph_atlas.GlyphAtlas;
const Sprite = glyph_atlas.Sprite;

/// The one bytecode format the build compiled shaders to. Declaring it pins the
/// backend, since SDL can only pick one that accepts it. Keep in step with
/// `shaderFormat` in build.zig.
const shader_target: struct {
    format: c.SDL_GPUShaderFormat,
    entrypoint: [*:0]const u8,
} = switch (builtin.target.os.tag) {
    .macos, .ios, .tvos, .watchos => .{ .format = c.SDL_GPU_SHADERFORMAT_MSL, .entrypoint = "main0" },
    else => .{ .format = c.SDL_GPU_SHADERFORMAT_SPIRV, .entrypoint = "main" },
};

const vertex_shader_code = @embedFile("quad.vert");
const fragment_shader_code = @embedFile("quad.frag");
const solid_shader_code = @embedFile("solid.frag");

/// Must match the uniform block in quad.vert.glsl. Both fields are vec2, the
/// same size and alignment in std140 as here.
const Frame = extern struct {
    viewport: [2]f32,
    atlas_size: [2]f32,
};

/// Must match the uniform block in quad.frag.glsl.
const Ink = extern struct {
    colour: [4]f32,
};

const initial_sprites = 4096;

pub const Renderer = struct {
    gpu: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    pipeline: *c.SDL_GPUGraphicsPipeline,

    /// Flat-colour quads (the caret, the scrollbar): a fragment shader that
    /// samples nothing, so a quad can be larger than anything in the atlas.
    solid: *c.SDL_GPUGraphicsPipeline,
    sampler: *c.SDL_GPUSampler,
    atlas: GlyphAtlas,

    /// Which palette every `Colour` resolves against, followed from the system.
    theme: config.Theme,

    /// The frame's sprites as the vertex shader indexes them, and the staging
    /// buffer they are written through. Kept and grown rather than made per frame.
    instances: *c.SDL_GPUBuffer,
    transfer: *c.SDL_GPUTransferBuffer,
    capacity: u32,

    /// Creates the device too: the shader format decides which backend SDL can
    /// pick, so the choice belongs with the shaders rather than the caller.
    pub fn init(allocator: std.mem.Allocator, window: *c.SDL_Window) !Renderer {
        const gpu = c.SDL_CreateGPUDevice(shader_target.format, false, null) orelse {
            std.log.err("SDL_CreateGPUDevice: {s}", .{sdl.lastError()});
            return error.SdlCreateGpuDevice;
        };
        errdefer c.SDL_DestroyGPUDevice(gpu);

        if (!c.SDL_ClaimWindowForGPUDevice(gpu, window)) {
            std.log.err("SDL_ClaimWindowForGPUDevice: {s}", .{sdl.lastError()});
            return error.SdlClaimWindow;
        }

        errdefer c.SDL_ReleaseWindowFromGPUDevice(gpu, window);

        const theme = sdl.systemTheme();

        // The layer exists now and not before.
        sdl.anchorContentsTopLeft(window);
        sdl.setLayerBackground(window, config.rgba(theme, .background));

        const device_name = c.SDL_GetStringProperty(
            c.SDL_GetGPUDeviceProperties(gpu),
            c.SDL_PROP_GPU_DEVICE_NAME_STRING,
            "unknown",
        );
        std.log.info("gpu backend: {s} on {s}", .{
            std.mem.span(c.SDL_GetGPUDeviceDriver(gpu)),
            std.mem.span(device_name),
        });

        const pipeline = try createPipeline(gpu, window, fragment_shader_code, .{
            .samplers = 1,
            .uniform_buffers = 1,
        });
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(gpu, pipeline);

        const solid = try createPipeline(gpu, window, solid_shader_code, .{ .uniform_buffers = 1 });
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(gpu, solid);

        var atlas = try GlyphAtlas.init(allocator, gpu, displayScale(window));
        errdefer atlas.deinit();

        // Nearest, not linear: quads are on whole pixels and sized to their
        // source, so every sample lands dead centre on a texel.
        const sampler = c.SDL_CreateGPUSampler(gpu, &std.mem.zeroInit(c.SDL_GPUSamplerCreateInfo, .{
            .min_filter = c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = c.SDL_GPU_FILTER_NEAREST,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        })) orelse {
            std.log.err("SDL_CreateGPUSampler: {s}", .{sdl.lastError()});
            return error.SdlCreateSampler;
        };
        errdefer c.SDL_ReleaseGPUSampler(gpu, sampler);

        const instances = try createInstanceBuffer(gpu, initial_sprites);
        errdefer c.SDL_ReleaseGPUBuffer(gpu, instances);

        const transfer = try createTransferBuffer(gpu, initial_sprites);

        return .{
            .gpu = gpu,
            .window = window,
            .pipeline = pipeline,
            .solid = solid,
            .sampler = sampler,
            .atlas = atlas,
            .instances = instances,
            .transfer = transfer,
            .capacity = initial_sprites,
            .theme = theme,
        };
    }

    pub fn deinit(self: *Renderer) void {
        c.SDL_ReleaseGPUTransferBuffer(self.gpu, self.transfer);
        c.SDL_ReleaseGPUBuffer(self.gpu, self.instances);
        c.SDL_ReleaseGPUGraphicsPipeline(self.gpu, self.solid);
        self.atlas.deinit();
        c.SDL_ReleaseGPUSampler(self.gpu, self.sampler);
        c.SDL_ReleaseGPUGraphicsPipeline(self.gpu, self.pipeline);
        c.SDL_ReleaseWindowFromGPUDevice(self.gpu, self.window);
        c.SDL_DestroyGPUDevice(self.gpu);
    }

    /// The colour comes off the run rather than the sprite: it changes once per
    /// call, where per-quad would upload four floats per glyph to repeat a value.
    pub fn present(self: *Renderer, painter: *Painter) !void {
        // Sorted so quads sharing a key end up adjacent, whoever produced them.
        // Safe to reorder because the key's layer says what stays on top.
        std.mem.sort(Run, painter.runs.items, {}, struct {
            fn less(_: void, a: Run, b: Run) bool {
                return painter_mod.Key.before({}, a.key, b.key);
            }
        }.less);

        const sprites = painter.quads.items;
        // A copy pass cannot be opened inside a render pass; here it also stays
        // out of the wait for a frame.
        try self.atlas.upload();

        const count: u32 = @intCast(sprites.len);
        try self.reserve(count);

        const cmd = c.SDL_AcquireGPUCommandBuffer(self.gpu) orelse {
            std.log.err("SDL_AcquireGPUCommandBuffer: {s}", .{sdl.lastError()});
            return error.SdlAcquireCommandBuffer;
        };

        // Before the swapchain, so it stays out of the wait for a frame.
        if (count > 0) self.stage(cmd, painter) catch |err| {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return err;
        };

        var swapchain: ?*c.SDL_GPUTexture = null;
        var width: u32 = 0;
        var height: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, self.window, &swapchain, &width, &height)) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            std.log.err("SDL_WaitAndAcquireGPUSwapchainTexture: {s}", .{sdl.lastError()});
            return error.SdlAcquireSwapchain;
        }

        // No texture without an error means the window is minimised; nothing to draw.
        if (swapchain == null) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return;
        }

        const ground = config.rgba(self.theme, .background);
        const target = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
            .texture = swapchain,
            .clear_color = c.SDL_FColor{
                .r = ground[0],
                .g = ground[1],
                .b = ground[2],
                .a = ground[3],
            },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
        });

        const pass = c.SDL_BeginGPURenderPass(cmd, &target, 1, null) orelse {
            std.log.err("SDL_BeginGPURenderPass: {s}", .{sdl.lastError()});
            return error.SdlBeginRenderPass;
        };
        if (count > 0) {
            const frame: Frame = .{
                .viewport = .{ @floatFromInt(width), @floatFromInt(height) },
                .atlas_size = glyph_atlas.size,
            };
            c.SDL_PushGPUVertexUniformData(cmd, 0, &frame, @sizeOf(Frame));

            const instances = [_]?*c.SDL_GPUBuffer{self.instances};
            const binding = std.mem.zeroInit(c.SDL_GPUTextureSamplerBinding, .{
                .texture = self.atlas.texture,
                .sampler = self.sampler,
            });

            // One call per key: runs sharing a key are contiguous after sorting.
            var bound: ?painter_mod.Pipeline = null;
            var i: usize = 0;
            while (i < painter.runs.items.len) {
                const run = painter.runs.items[i];

                var instances_in_call = run.count;
                var next = i + 1;
                while (next < painter.runs.items.len and
                    painter.runs.items[next].key.eql(run.key)) : (next += 1)
                {
                    instances_in_call += painter.runs.items[next].count;
                }

                if (bound == null or bound.? != run.key.pipeline) {
                    switch (run.key.pipeline) {
                        .glyphs => {
                            c.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);
                            c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
                        },
                        .solid => c.SDL_BindGPUGraphicsPipeline(pass, self.solid),
                    }
                    c.SDL_BindGPUVertexStorageBuffers(pass, 0, &instances, 1);
                    bound = run.key.pipeline;
                }

                const ink: Ink = .{ .colour = config.rgba(self.theme, run.key.colour) };
                c.SDL_PushGPUFragmentUniformData(cmd, 0, &ink, @sizeOf(Ink));
                c.SDL_DrawGPUPrimitives(pass, 4, instances_in_call, 0, run.first);

                i = next;
            }
        }

        c.SDL_EndGPURenderPass(pass);

        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
            std.log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdl.lastError()});
            return error.SdlSubmit;
        }
    }

    /// Doubling rather than fitting, so growing a glyph at a time does not
    /// reallocate a glyph at a time.
    fn reserve(self: *Renderer, count: u32) !void {
        if (count <= self.capacity) return;

        var capacity = self.capacity;
        while (capacity < count) capacity *= 2;

        const instances = try createInstanceBuffer(self.gpu, capacity);
        errdefer c.SDL_ReleaseGPUBuffer(self.gpu, instances);
        const transfer = try createTransferBuffer(self.gpu, capacity);

        // SDL holds a released resource until the GPU is done with it.
        c.SDL_ReleaseGPUBuffer(self.gpu, self.instances);
        c.SDL_ReleaseGPUTransferBuffer(self.gpu, self.transfer);

        self.instances = instances;
        self.transfer = transfer;
        self.capacity = capacity;
    }

    /// Copies run by run so the buffer ends up in the sorted order, each run's
    /// quads contiguous -- what lets one call cover several runs -- and leaves
    /// each run saying where it landed.
    fn stage(self: *Renderer, cmd: *c.SDL_GPUCommandBuffer, painter: *Painter) !void {
        const bytes = painter.quads.items.len * @sizeOf(Sprite);

        const mapped = c.SDL_MapGPUTransferBuffer(self.gpu, self.transfer, true) orelse {
            std.log.err("SDL_MapGPUTransferBuffer: {s}", .{sdl.lastError()});
            return error.SdlMapTransferBuffer;
        };
        const into = @as([*]Sprite, @ptrCast(@alignCast(mapped)));
        var at: u32 = 0;
        for (painter.runs.items) |*run| {
            @memcpy(into[at..][0..run.count], painter.quads.items[run.first..][0..run.count]);
            run.first = at;
            at += run.count;
        }
        c.SDL_UnmapGPUTransferBuffer(self.gpu, self.transfer);

        const source = std.mem.zeroInit(c.SDL_GPUTransferBufferLocation, .{
            .transfer_buffer = self.transfer,
        });
        const destination = std.mem.zeroInit(c.SDL_GPUBufferRegion, .{
            .buffer = self.instances,
            .size = @as(u32, @intCast(bytes)),
        });

        const pass = c.SDL_BeginGPUCopyPass(cmd);
        c.SDL_UploadToGPUBuffer(pass, &source, &destination, true);
        c.SDL_EndGPUCopyPass(pass);
    }
};

/// Pixel density and the size the user asked content to be, in one number. Not
/// density alone: Windows at 150% on an ordinary panel reports density one and
/// scale one-and-a-half, and sizing by density there would ignore the setting.
pub fn displayScale(window: *c.SDL_Window) f32 {
    // Zero is SDL's failure, and a font sized from it does not rasterise.
    const scale = c.SDL_GetWindowDisplayScale(window);
    return if (scale > 0) scale else 1;
}

fn createInstanceBuffer(gpu: *c.SDL_GPUDevice, capacity: u32) !*c.SDL_GPUBuffer {
    return c.SDL_CreateGPUBuffer(gpu, &std.mem.zeroInit(c.SDL_GPUBufferCreateInfo, .{
        .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
        .size = capacity * @sizeOf(Sprite),
    })) orelse {
        std.log.err("SDL_CreateGPUBuffer: {s}", .{sdl.lastError()});
        return error.SdlCreateBuffer;
    };
}

fn createTransferBuffer(gpu: *c.SDL_GPUDevice, capacity: u32) !*c.SDL_GPUTransferBuffer {
    return c.SDL_CreateGPUTransferBuffer(gpu, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = capacity * @sizeOf(Sprite),
    })) orelse {
        std.log.err("SDL_CreateGPUTransferBuffer: {s}", .{sdl.lastError()});
        return error.SdlCreateTransferBuffer;
    };
}

/// What a shader binds, which SDL needs told because bytecode does not say.
const Resources = struct {
    samplers: u32 = 0,
    storage_buffers: u32 = 0,
    uniform_buffers: u32 = 0,
};

fn createShader(
    gpu: *c.SDL_GPUDevice,
    stage: c.SDL_GPUShaderStage,
    resources: Resources,
    code: []const u8,
) !*c.SDL_GPUShader {
    return c.SDL_CreateGPUShader(gpu, &std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, .{
        .code = code.ptr,
        .code_size = code.len,
        .entrypoint = shader_target.entrypoint,
        .format = shader_target.format,
        .stage = stage,
        .num_samplers = resources.samplers,
        .num_storage_buffers = resources.storage_buffers,
        .num_uniform_buffers = resources.uniform_buffers,
    })) orelse {
        std.log.err("SDL_CreateGPUShader: {s}", .{sdl.lastError()});
        return error.SdlCreateShader;
    };
}

/// The two pipelines differ by their fragment shader and nothing else: same
/// vertex shader, same storage buffer, same blend, same target.
fn createPipeline(
    gpu: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    fragment_code: []const u8,
    fragment_resources: Resources,
) !*c.SDL_GPUGraphicsPipeline {
    const vertex = try createShader(gpu, c.SDL_GPU_SHADERSTAGE_VERTEX, .{
        .storage_buffers = 1,
        .uniform_buffers = 1,
    }, vertex_shader_code);
    defer c.SDL_ReleaseGPUShader(gpu, vertex);

    const fragment = try createShader(gpu, c.SDL_GPU_SHADERSTAGE_FRAGMENT, fragment_resources, fragment_code);
    defer c.SDL_ReleaseGPUShader(gpu, fragment);

    const color_target = std.mem.zeroInit(c.SDL_GPUColorTargetDescription, .{
        .format = c.SDL_GetGPUSwapchainTextureFormat(gpu, window),
        // Coverage arrives as alpha, and a quad is a bounding box that is
        // mostly empty, so glyphs blend rather than overwrite.
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
        std.log.err("SDL_CreateGPUGraphicsPipeline: {s}", .{sdl.lastError()});
        return error.SdlCreatePipeline;
    };
}

// The array goes to the GPU as it stands, so the Zig struct and the GLSL one
// have to agree byte for byte. Nothing else warns if that stops being true.
test "Sprite is laid out as the vertex shader reads it" {
    try std.testing.expectEqual(24, @sizeOf(Sprite));
    try std.testing.expectEqual(0, @offsetOf(Sprite, "dest"));
    try std.testing.expectEqual(8, @offsetOf(Sprite, "source"));
    try std.testing.expectEqual(16, @offsetOf(Sprite, "size"));
}

test "Ink is laid out as the fragment shader reads it" {
    try std.testing.expectEqual(16, @sizeOf(Ink));
    try std.testing.expectEqual(0, @offsetOf(Ink, "colour"));
}

test {
    // `main` never runs in a test build, so without this the atlas is compiled
    // out along with its tests.
    _ = @import("./glyph_atlas.zig");
}
