#version 450

// SDL_GPU binds fragment samplers in descriptor set 2. A GLSL sampler2D is a
// combined image sampler, which is exactly what the Vulkan backend expects.
layout(set = 2, binding = 0) uniform sampler2D atlas;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main()
{
    // The atlas stores coverage, not colour. It drives alpha, and the pipeline
    // blends the glyph over what is already there; a quad covers a glyph's
    // bounding box, so writing its empty corners opaquely would box the text in.
    out_color = vec4(1.0, 1.0, 1.0, texture(atlas, in_uv).r);
}
