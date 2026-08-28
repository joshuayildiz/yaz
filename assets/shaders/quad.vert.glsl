#version 450

// Generates a quad from the vertex index alone, as a 4-vertex triangle strip.
// No vertex buffer: the glyph renderer will drive geometry per instance instead.

layout(location = 0) out vec2 out_uv;

void main()
{
    vec2 corner = vec2(gl_VertexIndex & 1, (gl_VertexIndex >> 1) & 1);

    // SDL_GPU normalises clip space across backends: NDC is lower-left origin,
    // texture coordinates are upper-left, and no flipping belongs in the shader.
    out_uv = vec2(corner.x, 1.0 - corner.y);
    gl_Position = vec4((corner * 2.0 - 1.0) * 0.5, 0.0, 1.0);
}
