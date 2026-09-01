//! The file index: what the finder chooses between, and how it stays fresh.
//!
//! One library in place of the two binaries yaz used to spawn. It walks the
//! tree once, honours .gitignore, keeps the answer in memory, and watches for
//! changes on a thread of its own -- so a search is a function call against
//! something already there rather than `rg --files` piped into `fzf --filter`
//! on every keystroke.
//!
//! Loaded with `std.DynLib` rather than linked. fff ships a dynamic library and
//! no static one, and opening it ourselves keeps it out of the build entirely:
//! no Rust toolchain, no rpath, nothing for a cross-compile to arrange.
//! `std/Build/Watch/FsEvents.zig` reaches CoreServices the same way, for the
//! same reason.
//!
//! Everything past the handle goes through fff's accessor functions rather than
//! reading its structs. The header documents both, and calls the accessors the
//! supported path; taking it means a newer library cannot need a new
//! transcription here. Only `CreateOptions` is transcribed, because it is the
//! one thing that has to be passed in, and it is versioned so that it can be
//! appended to without breaking us.

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.target.os.tag == .windows;

/// What a search may cost before it is worth bounding. Well past a screenful:
/// the selection can move below the rows on screen, and asking again as it
/// moves would be a search per keystroke of the arrow key.
pub const page = 256;

/// Set on every `CreateOptions`. Tells the library which trailing fields are
/// populated, so one built after this was written still reads it correctly.
const options_version = 2;

/// Transcribed from `crates/fff-c/include/fff.h`. Fields are appended to and
/// never reordered, which is what `version` above is for.
const CreateOptions = extern struct {
    version: u32 = options_version,
    /// The directory to index. Required.
    base_path: [*:0]const u8,
    frecency_db_path: ?[*:0]const u8 = null,
    history_db_path: ?[*:0]const u8 = null,
    enable_mmap_cache: bool = false,
    enable_content_indexing: bool = false,
    /// The point of all this: a watcher, on a thread of the library's own.
    watch: bool = false,
    ai_mode: bool = false,
    log_file_path: ?[*:0]const u8 = null,
    log_level: ?[*:0]const u8 = null,
    cache_budget_max_files: u64 = 0,
    cache_budget_max_bytes: u64 = 0,
    cache_budget_max_file_size: u64 = 0,
    enable_fs_root_scanning: bool = false,
    enable_home_dir_scanning: bool = false,
    follow_symlinks: bool = false,
};

/// What every `fff_*` call answers with. The envelope is freed on its own; what
/// `handle` points at is not, and each kind has its own way of being let go.
const Result = extern struct {
    success: bool,
    err: ?[*:0]const u8,
    handle: ?*anyopaque,
    int_value: i64,
};

const Symbols = struct {
    create: *const fn (*const CreateOptions) callconv(.c) *Result,
    destroy: *const fn (*anyopaque) callconv(.c) void,
    search: *const fn (*anyopaque, [*:0]const u8, ?[*:0]const u8, u32, u32, u32, i32, u32) callconv(.c) *Result,

    free_result: *const fn (*Result) callconv(.c) void,
    free_search: *const fn (*anyopaque) callconv(.c) void,

    count: *const fn (*anyopaque) callconv(.c) u32,
    matched: *const fn (*anyopaque) callconv(.c) u32,
    files: *const fn (*anyopaque) callconv(.c) u32,
    item: *const fn (*anyopaque, u32) callconv(.c) ?*anyopaque,
    relative_path: *const fn (*anyopaque) callconv(.c) ?[*:0]const u8,

    /// Every symbol yaz uses, by the name it has in the library. Resolving all
    /// of them is also the health check -- `main` opens the library before it
    /// does anything else, so a truncated download or a library built for
    /// another architecture is caught there rather than at the first keystroke.
    const names = .{
        .{ "create", "fff_create_instance_with" },
        .{ "destroy", "fff_destroy" },
        .{ "search", "fff_search" },
        .{ "free_result", "fff_free_result" },
        .{ "free_search", "fff_free_search_result" },
        .{ "count", "fff_search_result_get_count" },
        .{ "matched", "fff_search_result_get_total_matched" },
        .{ "files", "fff_search_result_get_total_files" },
        .{ "item", "fff_search_result_get_item" },
        .{ "relative_path", "fff_file_item_get_relative_path" },
    };
};

pub const Error = error{ CannotOpenLibrary, MissingSymbol, CannotIndex, SearchFailed };

/// Loading a library, on the two paths there are.
///
/// `std.DynLib` covers Linux and the BSDs, Darwin among them, and stops at a
/// `@compileError` everywhere else -- Windows included. So Windows goes
/// straight to kernel32, which is what `dlopen` is a thin cover for on the
/// systems that have it.
const Loaded = if (windows) struct {
    module: std.os.windows.HMODULE,

    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?std.os.windows.HMODULE;
    extern "kernel32" fn GetProcAddress(module: std.os.windows.HMODULE, name: [*:0]const u8) callconv(.winapi) ?std.os.windows.FARPROC;
    extern "kernel32" fn FreeLibrary(module: std.os.windows.HMODULE) callconv(.winapi) std.os.windows.BOOL;

    fn open(path: []const u8) Error!Loaded {
        var wide: [std.fs.max_path_bytes]u16 = undefined;
        const written = std.unicode.utf8ToUtf16Le(&wide, path) catch return error.CannotOpenLibrary;
        if (written >= wide.len) return error.CannotOpenLibrary;
        wide[written] = 0;

        const module = LoadLibraryW(wide[0..written :0]) orelse return error.CannotOpenLibrary;
        return .{ .module = module };
    }

    fn lookup(self: *Loaded, comptime T: type, name: [:0]const u8) ?T {
        const found = GetProcAddress(self.module, name.ptr) orelse return null;
        return @ptrCast(@alignCast(found));
    }

    fn close(self: *Loaded) void {
        _ = FreeLibrary(self.module);
    }
} else struct {
    lib: std.DynLib,

    fn open(path: []const u8) Error!Loaded {
        return .{ .lib = std.DynLib.open(path) catch return error.CannotOpenLibrary };
    }

    fn lookup(self: *Loaded, comptime T: type, name: [:0]const u8) ?T {
        return self.lib.lookup(T, name);
    }

    fn close(self: *Loaded) void {
        self.lib.close();
    }
};

/// The library itself, opened but not yet asked anything.
pub const Library = struct {
    loaded: Loaded,
    at: Symbols,

    pub fn open(path: []const u8) Error!Library {
        var loaded = try Loaded.open(path);
        errdefer loaded.close();

        var at: Symbols = undefined;
        inline for (Symbols.names) |named| {
            const field = named[0];
            const Fn = @FieldType(Symbols, field);
            @field(at, field) = loaded.lookup(Fn, named[1]) orelse return error.MissingSymbol;
        }
        return .{ .loaded = loaded, .at = at };
    }

    pub fn close(self: *Library) void {
        self.loaded.close();
    }

    /// Starts indexing `root` and watching it. Returns before the first walk
    /// has finished -- it runs on a thread of the library's own, so a window
    /// can be up while it is still counting.
    pub fn index(self: *Library, root: [*:0]const u8) Error!Index {
        const answer = self.at.create(&.{ .base_path = root, .watch = true });
        defer self.at.free_result(answer);

        if (!answer.success) return error.CannotIndex;
        return .{ .at = self.at, .handle = answer.handle orelse return error.CannotIndex };
    }
};

/// The tree, as the library currently understands it.
pub const Index = struct {
    /// Copied rather than pointed at. Eleven pointers is nothing to carry, and
    /// it means an index does not care where the library it came from sits.
    at: Symbols,
    handle: *anyopaque,

    pub fn close(self: *Index) void {
        self.at.destroy(self.handle);
    }

    /// The paths matching `query`, best first. The caller owns what comes back.
    pub fn search(self: *const Index, query: [*:0]const u8) Error!Matches {
        // Zero means as many threads as the library likes. Fanning out costs
        // about 75us, which on a tree of 37 files is most of the search and on
        // one of 19,542 saves 1.4ms of 3.2 -- and the second is the number that
        // decides whether a keystroke feels immediate.
        const answer = self.at.search(self.handle, query, null, 0, 0, page, 0, 0);
        defer self.at.free_result(answer);

        if (!answer.success) return error.SearchFailed;
        const handle = answer.handle orelse return error.SearchFailed;
        return .{
            .at = self.at,
            .handle = handle,
            .count = self.at.count(handle),
            .matched = self.at.matched(handle),
            .files = self.at.files(handle),
        };
    }
};

/// What one search found. Owned: the paths point into it, so it outlives
/// nothing and is freed when the query changes.
pub const Matches = struct {
    at: Symbols,
    handle: *anyopaque,

    /// How many are here, how many matched in all, and how many the index
    /// holds. The last two are what the finder counts "n of m" with.
    count: u32,
    matched: u32,
    files: u32,

    pub fn deinit(self: *Matches) void {
        self.at.free_search(self.handle);
    }

    /// Borrowed, and only until this is freed.
    pub fn path(self: *const Matches, nth: u32) ?[]const u8 {
        if (nth >= self.count) return null;
        const item = self.at.item(self.handle, nth) orelse return null;
        return std.mem.span(self.at.relative_path(item) orelse return null);
    }
};

/// What the library is called on disk, which is also what `yaz setup` writes.
pub const library_name = switch (@import("builtin").target.os.tag) {
    .windows => "fff.dll",
    .macos => "libfff.dylib",
    else => "libfff.so",
};

test "the transcribed options struct is laid out as the C one is" {
    // The only thing here that has to agree with the library byte for byte,
    // since it is the only struct passed across. Taken from the header at the
    // pinned tag; a mistyped field shows up as a wrong offset rather than as a
    // library that misreads its own arguments.
    //
    // Nothing here checks the symbols: every launch does that already, in
    // `Model.locate`, which resolves all of them before the window goes up.
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(CreateOptions));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CreateOptions, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CreateOptions, "base_path"));
    try std.testing.expectEqual(@as(usize, 34), @offsetOf(CreateOptions, "watch"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(CreateOptions, "log_file_path"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(CreateOptions, "cache_budget_max_files"));
    try std.testing.expectEqual(@as(usize, 82), @offsetOf(CreateOptions, "follow_symlinks"));
}

test "a default options struct asks for nothing but a watched index" {
    const options: CreateOptions = .{ .base_path = "/tmp" };
    try std.testing.expectEqual(@as(u32, options_version), options.version);
    try std.testing.expect(!options.enable_content_indexing);
    try std.testing.expect(!options.ai_mode);
    try std.testing.expect(!options.enable_home_dir_scanning);
    try std.testing.expect(options.frecency_db_path == null);
}
