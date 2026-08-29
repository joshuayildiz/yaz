const std = @import("std");
const builtin = @import("builtin");

/// main.zig takes its SDL types from here rather than running its own
/// `@cImport`: two blocks that differ by so much as whitespace generate two
/// unrelated sets of types, and a `*SDL_Window` from one will not pass as a
/// `*SDL_Window` to the other.
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});


const glyph_atlas = @import("./glyph_atlas.zig");
const GlyphAtlas = glyph_atlas.GlyphAtlas;

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

/// SDL reports failures out of band; this is only meaningful right after one.
pub fn sdlError() []const u8 {
    return std.mem.span(c.SDL_GetError());
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
    atlas: GlyphAtlas,

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

        var atlas = try GlyphAtlas.init(gpa, gpu);
        errdefer atlas.deinit();

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
            .atlas = atlas,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.atlas.deinit();
        c.SDL_ReleaseGPUSampler(self.gpu, self.sampler);
        c.SDL_ReleaseGPUGraphicsPipeline(self.gpu, self.pipeline);
        c.SDL_ReleaseWindowFromGPUDevice(self.gpu, self.window);
        c.SDL_DestroyGPUDevice(self.gpu);
    }

    pub fn present(self: *Renderer, lines: []const []const u8) !void {
        // Laying out first is not tidiness. Uploading what the atlas was
        // missing is a copy pass, and a copy pass cannot be opened inside a
        // render pass. Doing it before the swapchain is acquired also keeps the
        // work out of the window between waiting for a frame and handing one
        // back.
        try self.atlas.layout(lines, 48, 48);
        try self.atlas.upload();

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
            .texture = self.atlas.texture,
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

    /// One quad per sprite. Everything about where they go was decided during
    /// layout; this only hands each one to the GPU.
    fn draw(
        self: *Renderer,
        cmd: *c.SDL_GPUCommandBuffer,
        pass: *c.SDL_GPURenderPass,
        viewport: [2]f32,
    ) void {
        for (self.atlas.sprites.items) |sprite| {
            const quad: Quad = .{
                .dest_origin = sprite.dest,
                .dest_size = sprite.size,
                .source_origin = sprite.source,
                .source_size = sprite.size,
                .viewport = viewport,
                .atlas_size = glyph_atlas.size,
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

test {
    // `main` never runs in a test build, so without this the atlas is compiled
    // out along with its tests.
    _ = @import("./glyph_atlas.zig");
}
