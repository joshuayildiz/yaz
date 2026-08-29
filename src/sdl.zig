//! The program's one `@cImport` of SDL.
//!
//! Two `@cImport` blocks that differ by so much as whitespace generate two
//! unrelated sets of types, and a `*SDL_Window` from one will not pass as a
//! `*SDL_Window` to the other. Everything that touches SDL takes its types from
//! here, so there is never a second block to differ from.

const std = @import("std");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

/// SDL reports failures out of band; this is only meaningful right after one.
pub fn lastError() []const u8 {
    return std.mem.span(c.SDL_GetError());
}
