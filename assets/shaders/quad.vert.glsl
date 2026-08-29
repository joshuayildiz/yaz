#version 450

// Generates a quad from the vertex index alone, as a 4-vertex triangle strip.
// No vertex buffer, and one instance per glyph: everything that differs between
// glyphs is read from the sprite buffer, so a screenful of text is a single
// draw call with nothing fed to it per glyph.

struct Sprite {
    // Where the glyph lands on screen, in pixels, top-left origin.
    vec2 dest;
    // Where it is in the atlas, in texels.
    vec2 source;
    // One size for both: a glyph is drawn at the size it was rasterised.
    vec2 size;
};

// SDL_GPU binds vertex storage buffers in descriptor set 0, after any textures,
// of which this pipeline has none.
layout(std430, set = 0, binding = 0) readonly buffer Sprites {
    Sprite sprites[];
};

// SDL_GPU binds vertex uniform buffers in descriptor set 1. What is left here
// is only what every glyph in the frame shares.
layout(set = 1, binding = 0) uniform Frame {
    vec2 viewport;
    vec2 atlas_size;
};

layout(location = 0) out vec2 out_uv;

void main()
{
    Sprite sprite = sprites[gl_InstanceIndex];
    vec2 corner = vec2(gl_VertexIndex & 1, (gl_VertexIndex >> 1) & 1);

    out_uv = (sprite.source + corner * sprite.size) / atlas_size;

    // Pixels count downwards and SDL_GPU normalises NDC to a lower-left origin
    // across backends, so y inverts here and nowhere else.
    vec2 pixel = sprite.dest + corner * sprite.size;
    gl_Position = vec4(
        pixel.x / viewport.x * 2.0 - 1.0,
        1.0 - pixel.y / viewport.y * 2.0,
        0.0,
        1.0);
}
