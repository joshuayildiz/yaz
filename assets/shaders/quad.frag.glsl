#version 450

// SDL_GPU binds fragment samplers in descriptor set 2. A GLSL sampler2D is a
// combined image sampler, which is exactly what the Vulkan backend expects.
layout(set = 2, binding = 0) uniform sampler2D atlas;

// SDL_GPU binds fragment uniform buffers in descriptor set 3. One colour per
// draw: the frame's glyphs are drawn in one call and the caret in a second, so
// what changes between them is this and nothing else. The caret goes through
// this shader too -- it samples a patch of the atlas that is opaque everywhere.
layout(set = 3, binding = 0) uniform Ink {
    vec4 colour;
};

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main()
{
    // The atlas stores coverage, not colour. It drives alpha, and the pipeline
    // blends the glyph over what is already there; a quad covers a glyph's
    // bounding box, so writing its empty corners opaquely would box the text in.
    out_color = vec4(colour.rgb, colour.a * texture(atlas, in_uv).r);
}
