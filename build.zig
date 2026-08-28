const std = @import("std");

const shaders = [_]Shader{
    .{ .name = "quad.vert", .glslang_stage = "vert", .shadercross_stage = "vertex" },
    .{ .name = "quad.frag", .glslang_stage = "frag", .shadercross_stage = "fragment" },
};

const Shader = struct {
    name: []const u8,
    glslang_stage: []const u8,
    shadercross_stage: []const u8,
};

/// Only the target's own bytecode is built. Keep in step with `shader_target`
/// in src/main.zig, which declares the format to SDL.
const Format = enum { spirv, msl };

fn shaderFormat(os: std.Target.Os.Tag) Format {
    return switch (os) {
        .macos, .ios, .tvos, .watchos => .msl,
        // Vulkan on Linux, and on Windows too: SDL_GPU's D3D12 backend would
        // need DXIL, which only DirectXShaderCompiler emits.
        else => .spirv,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl = b.dependency("sdl", .{ .target = target, .optimize = optimize });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.linkLibrary(sdl.artifact("SDL3"));
    addShaders(b, exe_mod, shaderFormat(target.result.os.tag));

    const exe = b.addExecutable(.{ .name = "yaz", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the editor");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}

/// Compiles each shader to the target's bytecode format and makes the result
/// importable, so `@embedFile` can reach it. The outputs are build artifacts in
/// the cache, never files in the source tree.
fn addShaders(b: *std.Build, module: *std.Build.Module, format: Format) void {
    // Fetches the compilers into vendor/toolchain on first use, no-op after.
    const setup = b.addSystemCommand(&.{
        "sh",
        b.pathFromRoot("vendor/setup-shader-toolchain.sh"),
        @tagName(format),
    });
    setup.has_side_effects = true;

    for (shaders) |shader| {
        const glslang = b.addSystemCommand(&.{
            b.pathFromRoot("vendor/toolchain/bin/glslang"),
            // --quiet, or glslang echoes the input path and the build system
            // treats a command that produces output files and chatter as failed.
            "-V", "--quiet", "--target-env", "vulkan1.0", "-S", shader.glslang_stage,
        });
        glslang.addFileArg(b.path(b.fmt("assets/shaders/{s}.glsl", .{shader.name})));
        glslang.addArg("-o");
        const spirv = glslang.addOutputFileArg(b.fmt("{s}.spv", .{shader.name}));
        glslang.step.dependOn(&setup.step);

        const blob = switch (format) {
            .spirv => spirv,
            // Metal has no SPIR-V ingestion; translate through SPIRV-Cross,
            // wrapped by shadercross so the binding conventions match SDL's.
            .msl => blk: {
                const translate = b.addSystemCommand(&.{b.pathFromRoot("vendor/toolchain/shadercross")});
                translate.addFileArg(spirv);
                translate.addArgs(&.{ "-s", "SPIRV", "-t", shader.shadercross_stage, "-d", "MSL", "-o" });
                break :blk translate.addOutputFileArg(b.fmt("{s}.msl", .{shader.name}));
            },
        };

        module.addAnonymousImport(shader.name, .{ .root_source_file = blob });
    }
}
