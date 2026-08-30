//! ripgrep and fzf: the two binaries yaz is built on, and how they arrive.
//!
//! Neither is bundled, and neither is looked for on `PATH` -- yaz runs what it
//! installed itself, so a different `rg` earlier on the path cannot quietly
//! change what the finder does.
//!
//! `yaz setup` downloads a pinned release of each and refuses anything whose
//! bytes do not hash to what is recorded below. That is the rule
//! vendor/setup-macos-sdk.sh already applies to the macOS SDK, for the same
//! reason: a downloaded binary is code we are about to run.

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.target.os.tag == .windows;

pub const Tool = enum {
    /// Lists the files the finder chooses between, honouring .gitignore.
    rg,
    /// Ranks them against what has been typed.
    fzf,

    pub const all = [_]Tool{ .rg, .fzf };

    /// What it is called on disk, which is also what it is called inside the
    /// archive it arrives in.
    pub fn binary(self: Tool) []const u8 {
        return switch (self) {
            .rg => if (windows) "rg.exe" else "rg",
            .fzf => if (windows) "fzf.exe" else "fzf",
        };
    }

    /// The project's name, for anything a person reads.
    pub fn title(self: Tool) []const u8 {
        return switch (self) {
            .rg => "ripgrep",
            .fzf => "fzf",
        };
    }
};

const rg_version = "15.2.0";
const fzf_version = "0.74.3";

const rg_base = "https://github.com/BurntSushi/ripgrep/releases/download/" ++ rg_version ++ "/";
const fzf_base = "https://github.com/junegunn/fzf/releases/download/v" ++ fzf_version ++ "/";

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

const Pins = struct { rg: Pin, fzf: Pin };

/// Taken from the checksum files published beside each release: ripgrep ships
/// one `.sha256` per asset, fzf one file for all of them.
///
/// A target with no entry here is one whose tools yaz cannot install, which is
/// better as a build error than as a surprise on someone's machine.
const pinned: Pins = switch (builtin.target.os.tag) {
    .macos => switch (builtin.target.cpu.arch) {
        .aarch64 => .{
            .rg = .{
                .url = rg_base ++ "ripgrep-" ++ rg_version ++ "-aarch64-apple-darwin.tar.gz",
                .sha256 = digestOf("3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4"),
            },
            .fzf = .{
                .url = fzf_base ++ "fzf-" ++ fzf_version ++ "-darwin_arm64.tar.gz",
                .sha256 = digestOf("1f8501cea4f9c0c2d6110d0ff75d0ec9451cd9d7524d9a26244a154ea89f3bd5"),
            },
        },
        .x86_64 => .{
            .rg = .{
                .url = rg_base ++ "ripgrep-" ++ rg_version ++ "-x86_64-apple-darwin.tar.gz",
                .sha256 = digestOf("af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1"),
            },
            .fzf = .{
                .url = fzf_base ++ "fzf-" ++ fzf_version ++ "-darwin_amd64.tar.gz",
                .sha256 = digestOf("b8a231250eedec244539ade3dc437bcd60e545a099c6cc0c8a11bdbd8574b9bc"),
            },
        },
        else => @compileError("no pinned ripgrep and fzf for this macOS architecture"),
    },
    .linux => switch (builtin.target.cpu.arch) {
        // musl rather than gnu: the same binary then runs whatever libc the
        // machine has, which is the point of installing one ourselves.
        .x86_64 => .{
            .rg = .{
                .url = rg_base ++ "ripgrep-" ++ rg_version ++ "-x86_64-unknown-linux-musl.tar.gz",
                .sha256 = digestOf("33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c"),
            },
            .fzf = .{
                .url = fzf_base ++ "fzf-" ++ fzf_version ++ "-linux_amd64.tar.gz",
                .sha256 = digestOf("3501a595e4b5c40a6b047340a0e8f805c46fd4e61ef95ef8a136ba8c61cf6f22"),
            },
        },
        .aarch64 => .{
            .rg = .{
                .url = rg_base ++ "ripgrep-" ++ rg_version ++ "-aarch64-unknown-linux-musl.tar.gz",
                .sha256 = digestOf("800b1e7206afe799dfb5a6901f23147cfaabe0e52210538100f61e86e1740915"),
            },
            .fzf = .{
                .url = fzf_base ++ "fzf-" ++ fzf_version ++ "-linux_arm64.tar.gz",
                .sha256 = digestOf("4a17a17b46bd0c4873e995533de508995c11572c0be0664a5dbcf13f60463046"),
            },
        },
        else => @compileError("no pinned ripgrep and fzf for this Linux architecture"),
    },
    .windows => switch (builtin.target.cpu.arch) {
        .x86_64 => .{
            .rg = .{
                .url = rg_base ++ "ripgrep-" ++ rg_version ++ "-x86_64-pc-windows-msvc.zip",
                .sha256 = digestOf("71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5"),
            },
            .fzf = .{
                .url = fzf_base ++ "fzf-" ++ fzf_version ++ "-windows_amd64.zip",
                .sha256 = digestOf("cf5c137d9b391c3988c54af8f5fc490ffbef6f70444651e7d57fdb45ad04c8bd"),
            },
        },
        else => @compileError("no pinned ripgrep and fzf for this Windows architecture"),
    },
    else => @compileError("no pinned ripgrep and fzf for this operating system"),
};

fn pin(tool: Tool) Pin {
    return switch (tool) {
        .rg => pinned.rg,
        .fzf => pinned.fzf,
    };
}

/// Where both tools live. Caller owns the result.
pub fn path(gpa: std.mem.Allocator, environ: std.process.Environ, tool: Tool) ![]u8 {
    const where = try home(gpa, environ);
    defer gpa.free(where);

    return pathUnder(gpa, where, tool);
}

/// The home directory. Caller owns the result.
///
/// `getPosix` reads the environment block directly; `getAlloc` builds a map of
/// the whole environment first, which measured 7.8ms per call in a Debug build.
/// It is only used where it has to be -- `getPosix` is not implemented on
/// Windows.
fn home(gpa: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    if (windows) {
        return environ.getAlloc(gpa, "USERPROFILE") catch error.NoHomeDirectory;
    }
    const found = environ.getPosix("HOME") orelse return error.NoHomeDirectory;
    return gpa.dupe(u8, found);
}

/// Apart from the environment so it can be tested without one.
fn pathUnder(gpa: std.mem.Allocator, where: []const u8, tool: Tool) ![]u8 {
    return std.fs.path.join(gpa, &.{ where, ".config", "yaz", "bin", tool.binary() });
}

/// Whether the binary at `exe` runs.
///
/// Spawned rather than stat-ed. A stat calls a truncated download, a
/// wrong-architecture binary, or one missing a shared library healthy, and the
/// finder would then be what discovered otherwise -- in the middle of a
/// keystroke, rather than at startup where it can be reported.
pub fn probe(gpa: std.mem.Allocator, io: std.Io, exe: []const u8) bool {
    const result = std.process.run(gpa, io, .{ .argv = &.{ exe, "--version" } }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Which tools are not working. Everything but the healthcheck is off while any
/// of them are.
pub const Missing = struct {
    rg: bool,
    fzf: bool,

    pub fn any(self: Missing) bool {
        return self.rg or self.fzf;
    }

    pub fn has(self: Missing, tool: Tool) bool {
        return switch (tool) {
            .rg => self.rg,
            .fzf => self.fzf,
        };
    }
};

pub fn missing(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !Missing {
    // Asked once rather than once per tool: it is the same answer both times.
    const where = try home(gpa, environ);
    defer gpa.free(where);

    var out: Missing = .{ .rg = true, .fzf = true };
    for (Tool.all) |tool| {
        const exe = try pathUnder(gpa, where, tool);
        defer gpa.free(exe);

        const working = probe(gpa, io, exe);
        switch (tool) {
            .rg => out.rg = !working,
            .fzf => out.fzf = !working,
        }
    }
    return out;
}

test "a tool's path is under the home directory it was given" {
    const gpa = std.testing.allocator;

    const rg = try pathUnder(gpa, "/Users/someone", .rg);
    defer gpa.free(rg);
    try std.testing.expectEqualStrings(
        if (windows) "/Users/someone\\.config\\yaz\\bin\\rg.exe" else "/Users/someone/.config/yaz/bin/rg",
        rg,
    );
}

test "every pinned url names the version it is pinned to" {
    for (Tool.all) |tool| {
        const p = pin(tool);
        try std.testing.expect(std.mem.startsWith(u8, p.url, "https://"));
        try std.testing.expectEqual(@as(usize, 32), p.sha256.len);

        const version = switch (tool) {
            .rg => rg_version,
            .fzf => fzf_version,
        };
        try std.testing.expect(std.mem.indexOf(u8, p.url, version) != null);
    }
}

/// Downloads the pinned release for `tool` and installs its binary.
///
/// Nothing is written until the archive hashes to the pin, and what is written
/// lands under a temporary name and is renamed into place -- so an install that
/// fails part way through leaves either the old binary or none, never half of a
/// new one for `probe` to have to explain.
pub fn install(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, tool: Tool) !void {
    const p = pin(tool);

    const exe = try path(gpa, environ, tool);
    defer gpa.free(exe);

    var archive: std.Io.Writer.Allocating = .init(gpa);
    defer archive.deinit();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const answer = client.fetch(.{
        .location = .{ .url = p.url },
        .response_writer = &archive.writer,
    }) catch |err| {
        std.log.err("{s}: {s}: {s}", .{ tool.title(), p.url, @errorName(err) });
        return error.DownloadFailed;
    };
    if (answer.status != .ok) {
        std.log.err("{s}: {s} answered {d}", .{ tool.title(), p.url, @intFromEnum(answer.status) });
        return error.DownloadFailed;
    }

    const bytes = archive.written();

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

    const partial = try std.fmt.allocPrint(gpa, "{s}.partial", .{tool.binary()});
    defer gpa.free(partial);
    errdefer dir.deleteFile(io, partial) catch {};

    try unpack(gpa, io, dir, bytes, tool, partial);
    try dir.rename(partial, dir, tool.binary(), io);
}

/// Writes the one file we came for out of the archive, and ignores the rest:
/// ripgrep ships its binary inside a versioned directory alongside a README, a
/// licence and man pages, fzf ships the binary alone. Matching on the name
/// rather than a path is what lets one rule cover both.
fn unpack(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    bytes: []const u8,
    tool: Tool,
    into: []const u8,
) !void {
    if (windows) return unpackZip(gpa, io, dir, bytes, tool, into);

    var input: std.Io.Reader = .fixed(bytes);
    var window: [64 * 1024]u8 = undefined;
    var gzip: std.compress.flate.Decompress = .init(&input, .gzip, &window);

    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var entries: std.tar.Iterator = .init(&gzip.reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });

    while (try entries.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.name), tool.binary())) continue;

        var file = try dir.createFile(io, into, .{ .permissions = .executable_file });
        defer file.close(io);

        var buffer: [64 * 1024]u8 = undefined;
        var out = file.writer(io, &buffer);
        try entries.streamRemaining(entry, &out.interface);
        try out.interface.flush();
        return;
    }

    std.log.err("{s}: no '{s}' inside the archive", .{ tool.title(), tool.binary() });
    return error.BinaryNotInArchive;
}

/// Windows releases are zips, which `std.zip` reads by seeking rather than by
/// streaming, so the bytes go to a file first.
fn unpackZip(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    bytes: []const u8,
    tool: Tool,
    into: []const u8,
) !void {
    const staging = "unpacking";
    try dir.writeFile(io, .{ .sub_path = staging ++ ".zip", .data = bytes });
    defer dir.deleteFile(io, staging ++ ".zip") catch {};

    var opened = try dir.openFile(io, staging ++ ".zip", .{});
    defer opened.close(io);

    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = opened.reader(io, &read_buffer);

    var unpacked = try dir.createDirPathOpen(io, staging, .{ .open_options = .{ .iterate = true } });
    defer unpacked.close(io);
    defer dir.deleteTree(io, staging) catch {};

    try std.zip.extract(unpacked, &reader, .{});

    var walker = try unpacked.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |found| {
        if (found.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(found.path), tool.binary())) continue;
        try unpacked.rename(found.path, dir, into, io);
        return;
    }

    std.log.err("{s}: no '{s}' inside the archive", .{ tool.title(), tool.binary() });
    return error.BinaryNotInArchive;
}
