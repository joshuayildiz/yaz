//! fff: the library the finder is built on, and how it arrives.
//!
//! Not bundled, and not looked for on any search path -- yaz loads what it
//! installed itself, so another copy elsewhere cannot quietly change what the
//! finder does.
//!
//! `yaz setup` downloads a pinned release and refuses anything whose bytes do
//! not hash to what is recorded below. That is the rule
//! vendor/setup-macos-sdk.sh already applies to the macOS SDK, for the same
//! reason: a downloaded library is code we are about to run.
//!
//! It replaced ripgrep and fzf, which were two binaries spawned as processes --
//! `rg --files` on every cmd+P and `fzf --filter` on every keystroke, with the
//! whole listing down a pipe each time. See src/fff.zig.

const std = @import("std");
const builtin = @import("builtin");

const fff = @import("./fff.zig");

const windows = builtin.target.os.tag == .windows;

pub const Tool = enum {
    /// Indexes the tree, keeps it fresh, and ranks it against what is typed.
    fff,

    pub const all = [_]Tool{.fff};

    /// What it is called on disk. An asset arrives named for the target it was
    /// built for, and is written under this.
    pub fn binary(self: Tool) []const u8 {
        return switch (self) {
            .fff => fff.library_name,
        };
    }

    /// The project's name, for anything a person reads.
    pub fn title(self: Tool) []const u8 {
        return switch (self) {
            .fff => "fff",
        };
    }
};

const fff_version = "0.10.6";
const fff_base = "https://github.com/dmtrKovalenko/fff/releases/download/v" ++ fff_version ++ "/";

/// The pin's hash as bytes. Comptime, so a mistyped constant is a build error
/// rather than a download that can never verify.
fn digestOf(comptime hex: []const u8) [32]u8 {
    return comptime blk: {
        var out: [32]u8 = undefined;
        const decoded = std.fmt.hexToBytes(&out, hex) catch @compileError("not hex: " ++ hex);
        if (decoded.len != out.len) @compileError("a pinned sha256 is not 32 bytes: " ++ hex);
        break :blk out;
    };
}

/// One pinned release artefact.
const Pin = struct {
    url: []const u8,
    /// Checked against the bytes as they arrive. Nothing is written unless it
    /// matches.
    sha256: [32]u8,
};

const Pins = struct { fff: Pin };

/// Taken from the `.sha256` published beside each asset. The assets are bare
/// libraries rather than archives, so what is downloaded is what is written.
///
/// A target with no entry here is one whose library yaz cannot install, which
/// is better as a build error than as a surprise on someone's machine.
const pinned: Pins = switch (builtin.target.os.tag) {
    .macos => switch (builtin.target.cpu.arch) {
        .aarch64 => .{ .fff = .{
            .url = fff_base ++ "c-lib-aarch64-apple-darwin.dylib",
            .sha256 = digestOf("5d66ccbe80d9506ef55f5fa0c3f05fb97a024de4c6d00cb6428d22155cad01aa"),
        } },
        .x86_64 => .{ .fff = .{
            .url = fff_base ++ "c-lib-x86_64-apple-darwin.dylib",
            .sha256 = digestOf("e4c055909fe59c9c441e949a6f7c0ea21638965821fc2385e4d4a391579bc5a2"),
        } },
        else => @compileError("no pinned fff for this macOS architecture"),
    },
    // gnu rather than musl. The musl asset is not static -- it is linked
    // against musl's own `libc.so`, which a glibc machine does not have, and
    // `dlopen` resolves that name to /lib/<triple>/libc.so, a linker script,
    // and fails with "invalid ELF header". The gnu asset asks for libc.so.6.
    .linux => switch (builtin.target.cpu.arch) {
        .x86_64 => .{ .fff = .{
            .url = fff_base ++ "c-lib-x86_64-unknown-linux-gnu.so",
            .sha256 = digestOf("c2d5b0acd0c86a412fa4c71ef32e0931c84a1f6022858a9b1bde49fba62ec940"),
        } },
        .aarch64 => .{ .fff = .{
            .url = fff_base ++ "c-lib-aarch64-unknown-linux-gnu.so",
            .sha256 = digestOf("707c0f2f4e09f79592f4c6f347bc43ccc65c11a543c3ca7bce78502249cb8d0f"),
        } },
        else => @compileError("no pinned fff for this Linux architecture"),
    },
    .windows => switch (builtin.target.cpu.arch) {
        .x86_64 => .{ .fff = .{
            .url = fff_base ++ "c-lib-x86_64-pc-windows-msvc.dll",
            .sha256 = digestOf("7da6fd485b8d8a3398cc403d37e5f1d0c5d7771840970576298e36e61e13249d"),
        } },
        else => @compileError("no pinned fff for this Windows architecture"),
    },
    else => @compileError("no pinned fff for this operating system"),
};

fn pin(tool: Tool) Pin {
    return switch (tool) {
        .fff => pinned.fff,
    };
}

/// Where both tools live. Caller owns the result.
pub fn path(allocator: std.mem.Allocator, environ: std.process.Environ, tool: Tool) ![]u8 {
    const where = try home(allocator, environ);
    defer allocator.free(where);

    return pathUnder(allocator, where, tool);
}

/// The home directory. Caller owns the result.
///
/// `getPosix` reads the environment block directly; `getAlloc` builds a map of
/// the whole environment first, which measured 7.8ms per call in a Debug build.
/// It is only used where it has to be -- `getPosix` is not implemented on
/// Windows.
fn home(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    if (windows) {
        return environ.getAlloc(allocator, "USERPROFILE") catch error.NoHomeDirectory;
    }
    const found = environ.getPosix("HOME") orelse return error.NoHomeDirectory;
    return allocator.dupe(u8, found);
}

/// Apart from the environment so it can be tested without one.
fn pathUnder(allocator: std.mem.Allocator, where: []const u8, tool: Tool) ![]u8 {
    return std.fs.path.join(allocator, &.{ where, ".config", "yaz", "lib", tool.binary() });
}

/// Whether the library at `exe` loads and has everything yaz calls.
///
/// Opened rather than stat-ed. A stat calls a truncated download or a library
/// built for another architecture healthy, and the finder would then be what
/// discovered otherwise -- in the middle of a keystroke, rather than at startup
/// where it can be reported.
///
/// This used to spawn `--version`, back when the tools were executables, and
/// two spawns of a 4MB binary cost 11ms of every launch (OPTIMIZATIONS 12).
/// Loading a library yaz is about to load anyway costs a fraction of that and
/// checks more: every symbol has to resolve, not just the entry point.
pub fn probe(exe: []const u8) bool {
    var lib = fff.Library.open(exe) catch return false;
    lib.close();
    return true;
}

/// Which tools are not working. Everything but the healthcheck is off while any
/// of them are.
pub const Missing = struct {
    fff: bool,

    pub fn has(self: Missing, tool: Tool) bool {
        return switch (tool) {
            .fff => self.fff,
        };
    }
};

test "a tool's path is under the home directory it was given" {
    const allocator = std.testing.allocator;

    const found = try pathUnder(allocator, "/Users/someone", .fff);
    defer allocator.free(found);
    try std.testing.expectEqualStrings(
        if (windows)
            "/Users/someone\\.config\\yaz\\lib\\" ++ fff.library_name
        else
            "/Users/someone/.config/yaz/lib/" ++ fff.library_name,
        found,
    );
}

test "every pinned url names the version it is pinned to" {
    for (Tool.all) |tool| {
        const p = pin(tool);
        try std.testing.expect(std.mem.startsWith(u8, p.url, "https://"));
        try std.testing.expectEqual(@as(usize, 32), p.sha256.len);

        const version = switch (tool) {
            .fff => fff_version,
        };
        try std.testing.expect(std.mem.indexOf(u8, p.url, version) != null);
    }
}

/// Downloads the pinned release for `tool` and installs it.
///
/// Nothing is written until the bytes hash to the pin, and what is written
/// lands under a temporary name and is renamed into place -- so an install that
/// fails part way through leaves either the old library or none, never half of
/// a new one for `probe` to have to explain.
///
/// The asset is the library itself rather than an archive holding it, so there
/// is nothing to unpack: what was verified is what is written.
pub fn install(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, tool: Tool) !void {
    const p = pin(tool);

    const exe = try path(allocator, environ, tool);
    defer allocator.free(exe);

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const answer = client.fetch(.{
        .location = .{ .url = p.url },
        .response_writer = &body.writer,
    }) catch |err| {
        std.log.err("{s}: {s}: {s}", .{ tool.title(), p.url, @errorName(err) });
        return error.DownloadFailed;
    };
    if (answer.status != .ok) {
        std.log.err("{s}: {s} answered {d}", .{ tool.title(), p.url, @intFromEnum(answer.status) });
        return error.DownloadFailed;
    }

    const bytes = body.written();

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &p.sha256)) {
        std.log.err(
            "{s}: checksum mismatch, refusing to install what came back from {s}",
            .{ tool.title(), p.url },
        );
        return error.ChecksumMismatch;
    }

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, std.fs.path.dirname(exe).?, .{});
    defer dir.close(io);

    const partial = try std.fmt.allocPrint(allocator, "{s}.partial", .{tool.binary()});
    defer allocator.free(partial);
    errdefer dir.deleteFile(io, partial) catch {};

    // Executable, even though nothing runs it: a library loaded by `dlopen`
    // needs the bit on macOS, and it costs nothing where it does not.
    try dir.writeFile(io, .{
        .sub_path = partial,
        .data = bytes,
        .flags = .{ .permissions = .executable_file },
    });
    try dir.rename(partial, dir, tool.binary(), io);
}
