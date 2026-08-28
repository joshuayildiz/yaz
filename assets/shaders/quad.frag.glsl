#version 450

// SDL_GPU binds fragment samplers in descriptor set 2. A GLSL sampler2D is a
// combined image sampler, which is exactly what the Vulkan backend expects.
layout(set = 2, binding = 0) uniform sampler2D atlas;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main()
{
    // Single-channel coverage, as the glyph atlas will be.
    float coverage = texture(atlas, in_uv).r;
    out_color = vec4(coverage, coverage, coverage, 1.0);
}
