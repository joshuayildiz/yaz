//! The file index: what the finder chooses between, and how it stays fresh.
//!
//! One library, walked once and kept in memory with a watcher on its own thread,
//! in place of `rg --files | fzf --filter` spawned on every keystroke.
//!
//! Loaded with `std.DynLib` rather than linked: fff ships only a dynamic library,
//! and opening it ourselves keeps it out of the build -- no Rust toolchain, no
//! rpath, nothing for a cross-compile to arrange.
//!
//! Everything past the handle goes through fff's accessor functions rather than
//! reading its structs, so a newer library cannot need a new transcription here.
//! Only `CreateOptions` is transcribed, since it has to be passed in, and it is
//! versioned so it can be appended to without breaking us.

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.target.os.tag == .windows;

/// Well past a screenful: the selection can move below the rows on screen, and
/// asking again as it moves would be a search per arrow keystroke.
pub const page = 256;

/// The whole listing for the sidebar, not the finder's ranked handful -- still a
/// bound, since a repository can hold more files than anyone folds open at once.
pub const tree_page = 8192;

/// Called from the library's watcher thread. The callee owns `batch` and must
/// let it go with `freeWatchEvents`.
pub const WatchCallback = *const fn (u64, ?*anyopaque, ?*anyopaque) callconv(.c) void;

/// Tells the library which trailing `CreateOptions` fields are populated, so one
/// built after this was written still reads it correctly.
const options_version = 2;

/// Transcribed from `crates/fff-c/include/fff.h`. Appended to, never reordered,
/// which is what `version` is for.
const CreateOptions = extern struct {
    version: u32 = options_version,
    /// The directory to index. Required.
    base_path: [*:0]const u8,
    frecency_db_path: ?[*:0]const u8 = null,
    history_db_path: ?[*:0]const u8 = null,
    enable_mmap_cache: bool = false,
    enable_content_indexing: bool = false,
    /// A watcher, on a thread of the library's own.
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
/// `handle` points at is not, and each kind is let go its own way.
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

    set_watch_callback: *const fn (*anyopaque, WatchCallback, ?*anyopaque) callconv(.c) *Result,
    watch: *const fn (*anyopaque, ?[*:0]const u8, ?*const anyopaque) callconv(.c) *Result,
    unwatch: *const fn (*anyopaque, u64) callconv(.c) *Result,
    free_watch_events: *const fn (*anyopaque) callconv(.c) void,

    /// Every symbol yaz uses, by its name in the library. Resolving all of them
    /// at startup is also the health check: a truncated download or a wrong-arch
    /// library is caught then rather than at the first keystroke.
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
        .{ "set_watch_callback", "fff_set_watch_callback" },
        .{ "watch", "fff_watch" },
        .{ "unwatch", "fff_unwatch" },
        .{ "free_watch_events", "fff_free_watch_events" },
    };
};

pub const Error = error{ CannotOpenLibrary, MissingSymbol, CannotIndex, SearchFailed, WatchFailed };

/// The one symbol a watch callback needs but cannot be handed: it runs on the
/// library's thread with nothing but the batch. A global so the callback can
/// reach it without carrying every symbol across the FFI boundary.
var watch_free: ?*const fn (*anyopaque) callconv(.c) void = null;

/// Frees a batch handed to a `WatchCallback`.
pub fn freeWatchEvents(batch: *anyopaque) void {
    if (watch_free) |free| free(batch);
}

/// `std.DynLib` covers Linux and the BSDs, Darwin among them, but `@compileError`s
/// on Windows, so Windows goes straight to kernel32.
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
        watch_free = at.free_watch_events;
        return .{ .loaded = loaded, .at = at };
    }

    pub fn close(self: *Library) void {
        self.loaded.close();
    }

    /// Starts indexing `root` and watching it. Returns before the first walk has
    /// finished -- it runs on the library's own thread -- so a window can be up
    /// while it is still counting.
    pub fn index(self: *Library, root: [*:0]const u8) Error!Index {
        const answer = self.at.create(&.{ .base_path = root, .watch = true });
        defer self.at.free_result(answer);

        if (!answer.success) return error.CannotIndex;
        return .{ .at = self.at, .handle = answer.handle orelse return error.CannotIndex };
    }
};

pub const Index = struct {
    /// Copied rather than pointed at, so an index does not care where the library
    /// it came from sits.
    at: Symbols,
    handle: *anyopaque,

    pub fn close(self: *Index) void {
        self.at.destroy(self.handle);
    }

    /// The paths matching `query`, best first. The caller owns what comes back.
    pub fn search(self: *const Index, query: [*:0]const u8) Error!Matches {
        // Zero threads means as many as the library likes; on a large tree that
        // fan-out saves ~1.4ms of ~3.2, which is what decides whether a keystroke
        // feels immediate.
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

    /// Every indexed path, for the tree to fold into a listing: an empty query
    /// against a wide page. The caller owns what comes back, as with `search`.
    pub fn enumerate(self: *const Index) Error!Matches {
        const answer = self.at.search(self.handle, "", null, 0, 0, tree_page, 0, 0);
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

    /// Subscribes to every change under the root, delivered to `callback` on the
    /// library's own thread. Answers with the id `unwatch` takes. The callback is
    /// instance-wide and just replaced when set again, so opening and closing the
    /// tree repeatedly needs no bookkeeping.
    pub fn watch(self: *const Index, callback: WatchCallback, user_data: ?*anyopaque) Error!u64 {
        const registered = self.at.set_watch_callback(self.handle, callback, user_data);
        defer self.at.free_result(registered);
        if (!registered.success) return error.WatchFailed;

        // Null pattern is everything, null options the defaults.
        const answer = self.at.watch(self.handle, null, null);
        defer self.at.free_result(answer);
        if (!answer.success) return error.WatchFailed;
        return @bitCast(answer.int_value);
    }

    /// Stops one subscription. The callback stays set, costing nothing idle.
    pub fn unwatch(self: *const Index, id: u64) void {
        const answer = self.at.unwatch(self.handle, id);
        self.at.free_result(answer);
    }
};

/// What one search found. Owned: the paths point into it, and it is freed when
/// the query changes.
pub const Matches = struct {
    at: Symbols,
    handle: *anyopaque,

    /// How many are here, how many matched in all, how many the index holds. The
    /// last two are the finder's "n of m".
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

/// The library's name on disk, which is also what `yaz setup` writes.
pub const library_name = switch (@import("builtin").target.os.tag) {
    .windows => "fff.dll",
    .macos => "libfff.dylib",
    else => "libfff.so",
};

test "the transcribed options struct is laid out as the C one is" {
    // The only struct passed across, so the only one that must agree byte for
    // byte: a mistyped field shows up here as a wrong offset. The symbols are
    // checked at every launch instead, in `Model.locate`.
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
