#version 450

// Generates a quad from the vertex index alone, as a 4-vertex triangle strip.
// No vertex buffer: one uniform push per glyph, and the geometry follows from
// it. Instancing replaces the per-glyph push once shaping lands.

// SDL_GPU binds vertex uniform buffers in descriptor set 1.
layout(set = 1, binding = 0) uniform Quad {
    // Where the glyph lands on screen, in pixels, top-left origin.
    vec2 dest_origin;
    vec2 dest_size;
    // Where it is in the atlas, in texels.
    vec2 source_origin;
    vec2 source_size;
    vec2 viewport;
    vec2 atlas_size;
};

layout(location = 0) out vec2 out_uv;

void main()
{
    vec2 corner = vec2(gl_VertexIndex & 1, (gl_VertexIndex >> 1) & 1);

    out_uv = (source_origin + corner * source_size) / atlas_size;

    // Pixels count downwards and SDL_GPU normalises NDC to a lower-left origin
    // across backends, so y inverts here and nowhere else.
    vec2 pixel = dest_origin + corner * dest_size;
    gl_Position = vec4(
        pixel.x / viewport.x * 2.0 - 1.0,
        1.0 - pixel.y / viewport.y * 2.0,
        0.0,
        1.0);
}
