#version 450

// No atlas: a solid quad is its colour and nothing else, which is the whole
// reason it does not go through the pipeline that samples one. Freed from a
// source rectangle, it can be any size -- a scrollbar is taller than any glyph.
layout(set = 3, binding = 0) uniform Ink {
    vec4 colour;
};

// Declared and unused. The vertex shader is shared with the glyph pipeline and
// writes it; leaving it out would make the two stages disagree about what
// passes between them.
layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main()
{
    out_color = colour;
}
