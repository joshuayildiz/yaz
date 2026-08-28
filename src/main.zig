const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
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

const atlas_size = 64;

/// SDL reports failures out of band; this is only meaningful right after one.
fn sdlError() []const u8 {
    return std.mem.span(c.SDL_GetError());
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.err("SDL_Init: {s}", .{sdlError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("yaz", 1024, 768, c.SDL_WINDOW_RESIZABLE) orelse {
        std.log.err("SDL_CreateWindow: {s}", .{sdlError()});
        return error.SdlCreateWindow;
    };
    defer c.SDL_DestroyWindow(window);

    const gpu = c.SDL_CreateGPUDevice(shader_target.format, false, null) orelse {
        std.log.err("SDL_CreateGPUDevice: {s}", .{sdlError()});
        return error.SdlCreateGpuDevice;
    };
    defer c.SDL_DestroyGPUDevice(gpu);

    if (!c.SDL_ClaimWindowForGPUDevice(gpu, window)) {
        std.log.err("SDL_ClaimWindowForGPUDevice: {s}", .{sdlError()});
        return error.SdlClaimWindow;
    }
    defer c.SDL_ReleaseWindowFromGPUDevice(gpu, window);

    const device_name = c.SDL_GetStringProperty(
        c.SDL_GetGPUDeviceProperties(gpu),
        c.SDL_PROP_GPU_DEVICE_NAME_STRING,
        "unknown",
    );
    std.log.info("video driver: {s}", .{std.mem.span(c.SDL_GetCurrentVideoDriver())});
    std.log.info("gpu backend: {s} on {s}", .{
        std.mem.span(c.SDL_GetGPUDeviceDriver(gpu)),
        std.mem.span(device_name),
    });

    const pipeline = try createPipeline(gpu, window);
    defer c.SDL_ReleaseGPUGraphicsPipeline(gpu, pipeline);

    const atlas = try createAtlas(gpu);
    defer c.SDL_ReleaseGPUTexture(gpu, atlas);

    const sampler = c.SDL_CreateGPUSampler(gpu, &std.mem.zeroInit(c.SDL_GPUSamplerCreateInfo, .{
        .min_filter = c.SDL_GPU_FILTER_LINEAR,
        .mag_filter = c.SDL_GPU_FILTER_LINEAR,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
    })) orelse {
        std.log.err("SDL_CreateGPUSampler: {s}", .{sdlError()});
        return error.SdlCreateSampler;
    };
    defer c.SDL_ReleaseGPUSampler(gpu, sampler);

    // Blocking wait, not a poll loop: idle costs nothing.
    var event: c.SDL_Event = undefined;
    while (true) {
        try present(gpu, window, pipeline, atlas, sampler);
        if (!c.SDL_WaitEvent(&event)) {
            std.log.err("SDL_WaitEvent: {s}", .{sdlError()});
            return error.SdlWaitEvent;
        }
        if (event.type == c.SDL_EVENT_QUIT) break;
    }
}

fn createShader(
    gpu: *c.SDL_GPUDevice,
    stage: c.SDL_GPUShaderStage,
    num_samplers: u32,
    code: []const u8,
) !*c.SDL_GPUShader {
    return c.SDL_CreateGPUShader(gpu, &std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, .{
        .code = code.ptr,
        .code_size = code.len,
        .entrypoint = shader_target.entrypoint,
        .format = shader_target.format,
        .stage = stage,
        .num_samplers = num_samplers,
    })) orelse {
        std.log.err("SDL_CreateGPUShader: {s}", .{sdlError()});
        return error.SdlCreateShader;
    };
}

fn createPipeline(gpu: *c.SDL_GPUDevice, window: *c.SDL_Window) !*c.SDL_GPUGraphicsPipeline {
    const vertex = try createShader(gpu, c.SDL_GPU_SHADERSTAGE_VERTEX, 0, vertex_shader_code);
    defer c.SDL_ReleaseGPUShader(gpu, vertex);

    const fragment = try createShader(gpu, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 1, fragment_shader_code);
    defer c.SDL_ReleaseGPUShader(gpu, fragment);

    const color_target = std.mem.zeroInit(c.SDL_GPUColorTargetDescription, .{
        .format = c.SDL_GetGPUSwapchainTextureFormat(gpu, window),
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

/// Stand-in for the glyph atlas: single channel, same format and upload path.
fn createAtlas(gpu: *c.SDL_GPUDevice) !*c.SDL_GPUTexture {
    var pixels: [atlas_size * atlas_size]u8 = undefined;
    for (0..atlas_size) |y| {
        for (0..atlas_size) |x| {
            // Solid block in the first rows and columns, so that a vertically
            // flipped image is obvious rather than hidden by the symmetry.
            const marker = x < atlas_size / 4 and y < atlas_size / 4;
            const dark = (x / 8 + y / 8) % 2 == 0;
            pixels[y * atlas_size + x] = if (marker) 0xff else if (dark) 0x20 else 0xe0;
        }
    }

    const texture = c.SDL_CreateGPUTexture(gpu, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = atlas_size,
        .height = atlas_size,
        .layer_count_or_depth = 1,
        .num_levels = 1,
    })) orelse {
        std.log.err("SDL_CreateGPUTexture: {s}", .{sdlError()});
        return error.SdlCreateTexture;
    };

    const transfer = c.SDL_CreateGPUTransferBuffer(gpu, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = pixels.len,
    })) orelse {
        std.log.err("SDL_CreateGPUTransferBuffer: {s}", .{sdlError()});
        return error.SdlCreateTransferBuffer;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(gpu, transfer);

    const mapped = c.SDL_MapGPUTransferBuffer(gpu, transfer, false) orelse {
        std.log.err("SDL_MapGPUTransferBuffer: {s}", .{sdlError()});
        return error.SdlMapTransferBuffer;
    };
    @memcpy(@as([*]u8, @ptrCast(mapped))[0..pixels.len], &pixels);
    c.SDL_UnmapGPUTransferBuffer(gpu, transfer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(gpu) orelse {
        std.log.err("SDL_AcquireGPUCommandBuffer: {s}", .{sdlError()});
        return error.SdlAcquireCommandBuffer;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd);
    const source = std.mem.zeroInit(c.SDL_GPUTextureTransferInfo, .{
        .transfer_buffer = transfer,
        .pixels_per_row = atlas_size,
        .rows_per_layer = atlas_size,
    });
    const destination = std.mem.zeroInit(c.SDL_GPUTextureRegion, .{
        .texture = texture,
        .w = atlas_size,
        .h = atlas_size,
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

fn present(
    gpu: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    atlas: *c.SDL_GPUTexture,
    sampler: *c.SDL_GPUSampler,
) !void {
    const cmd = c.SDL_AcquireGPUCommandBuffer(gpu) orelse {
        std.log.err("SDL_AcquireGPUCommandBuffer: {s}", .{sdlError()});
        return error.SdlAcquireCommandBuffer;
    };

    var swapchain: ?*c.SDL_GPUTexture = null;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &swapchain, null, null)) {
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

    const pass = c.SDL_BeginGPURenderPass(cmd, &target, 1, null);
    c.SDL_BindGPUGraphicsPipeline(pass, pipeline);
    const binding = std.mem.zeroInit(c.SDL_GPUTextureSamplerBinding, .{
        .texture = atlas,
        .sampler = sampler,
    });
    c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
    c.SDL_DrawGPUPrimitives(pass, 4, 1, 0, 0);
    c.SDL_EndGPURenderPass(pass);

    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
        std.log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdlError()});
        return error.SdlSubmit;
    }
}
