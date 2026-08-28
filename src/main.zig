const std = @import("std");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

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

    // One format per backend we target: SPIR-V on Vulkan, DXIL on D3D12, MSL on Metal.
    const gpu = c.SDL_CreateGPUDevice(
        c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_DXIL | c.SDL_GPU_SHADERFORMAT_MSL,
        false,
        null,
    ) orelse {
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

    // Blocking wait, not a poll loop: idle costs nothing.
    var event: c.SDL_Event = undefined;
    while (true) {
        try present(gpu, window);
        if (!c.SDL_WaitEvent(&event)) {
            std.log.err("SDL_WaitEvent: {s}", .{sdlError()});
            return error.SdlWaitEvent;
        }
        if (event.type == c.SDL_EVENT_QUIT) break;
    }
}

fn present(gpu: *c.SDL_GPUDevice, window: *c.SDL_Window) !void {
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
    c.SDL_EndGPURenderPass(pass);

    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
        std.log.err("SDL_SubmitGPUCommandBuffer: {s}", .{sdlError()});
        return error.SdlSubmit;
    }
}
