#version 450

// SDL_GPU binds fragment samplers in set 2 and fragment uniforms in set 3.
layout(set = 2, binding = 0) uniform sampler2D atlas;

// One colour per draw: glyphs are one call and the caret a second, and this is
// all that changes between them.
layout(set = 3, binding = 0) uniform Ink {
    vec4 colour;
};

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main()
{
    // Coverage drives alpha: a quad covers a glyph's bounding box, so writing
    // its empty corners opaquely would box the text in.
    out_color = vec4(colour.rgb, colour.a * texture(atlas, in_uv).r);
}
