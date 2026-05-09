/// main_daemon.zig — `awrd` daemon entry point.
///
/// Implementation slice 1 (B3.2 minimal viable): listens on a Unix
/// domain socket, accepts connections sequentially, reads
/// Content-Length-framed JSON-RPC 2.0 requests via `jsonrpc.zig`, and
/// dispatches to a small in-process method table. v1 covers `ping`
/// (returns pong + version) and `shutdown` (graceful exit). `fetch`,
/// `tools`, `call` arrive in subsequent slices per
/// `spec/subspecs/daemon-mode.md §6`.
///
/// Sequential accept (no per-connection thread) is correct for v1 —
/// the spec calls for "one agent, one request at a time"; concurrent
/// requests are a future-work item gated on Page-instance isolation.
///
/// Socket path resolution per `spec/subspecs/daemon-mode.md §2.1`:
///   `${XDG_RUNTIME_DIR:-/tmp}/awrd-${UID}.sock`
const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const build_opts = @import("build_opts");
const page_mod = @import("page");

// Re-exports surfaced through page so the daemon doesn't need its own
// named imports for cookie/client. Keeps build.zig's daemon_mod deps
// narrow (just `page` + `build_opts`).
const CookieJar = page_mod.CookieJar;

/// Maximum body bytes per request frame. 1 MiB is generous for v1
/// (typical fetch param JSON is well under 1 KB; even multi-redirect
/// responses are <100 KB). Enforced inside readFrame so the daemon
/// can't be DOSed by a peer that streams a huge Content-Length.
const MAX_BODY_BYTES: usize = 1 * 1024 * 1024;

/// Per-connection read/write buffer sizes. Frame headers sit under
/// MAX_HEADER_LINE (4 KiB) and bodies are bounded above; 16 KiB read
/// + 16 KiB write covers the steady state with one reallocation
/// budget for outsized frames.
const READ_BUFFER_BYTES: usize = 16 * 1024;
const WRITE_BUFFER_BYTES: usize = 16 * 1024;

pub fn run(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8) !void {
    // Pre-flight: remove any leftover socket file from a previous
    // crashed run. Spec §2.5's "double-fork + flock pid file" path
    // owns crash-survivor handling; for v1 we keep it simple.
    std.Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {}, // expected — first run
        else => return err,
    };

    const ua = try std.Io.net.UnixAddress.init(socket_path);
    var server = try ua.listen(io, .{});
    defer server.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};

    // Per-scope cookie jar cache (spec §5.3 in-memory persistence).
    // Lifetime: daemon process. Each fetch get-or-creates an entry
    // for its scope; the cached jar survives across requests so
    // session cookies (no Max-Age) round-trip correctly.
    var jar_cache: JarCache = .empty;
    defer jar_cache.deinit(allocator, io);

    log("awrd: listening on {s} version=0.0.{s}", .{ socket_path, build_opts.git_hash });

    var should_exit = false;
    while (!should_exit) {
        var stream = server.accept(io) catch |err| {
            log("awrd: accept failed: {t}", .{err});
            continue;
        };
        defer stream.close(io);

        handleConnection(allocator, io, &stream, &should_exit, &jar_cache) catch |err| {
            log("awrd: connection error: {t}", .{err});
        };
    }
    log("awrd: shutdown complete", .{});
}

/// Per-scope cookie-jar cache for the daemon. One entry per scope
/// name; the entry owns both the heap-allocated CookieJar and the
/// resolved on-disk path. Lookup is by scope string; on miss, the
/// entry is created fresh: the on-disk file is loaded if present,
/// then the entry is inserted into the map. After each fetch the
/// caller calls `persist(entry, io)` to flush durability changes
/// back to disk; on shutdown `deinit` saves+frees everything.
///
/// Hash-map lifetimes:
///   - Keys (scope strings) are duplicated on insert and freed on
///     deinit. Map values (entries) are heap-allocated; the map
///     stores `*Entry` so the borrowed `*CookieJar` pointer in
///     ClientOptions remains stable across re-hashes.
const JarCache = struct {
    entries: std.StringHashMapUnmanaged(*Entry) = .empty,

    const Entry = struct {
        jar: CookieJar,
        path: ?[]u8, // null when no XDG path could be resolved
    };

    pub const empty: JarCache = .{};

    /// Borrow (or load-and-cache) the jar for `scope`. Returned
    /// pointer is stable for the daemon's lifetime — the value's
    /// in-place `jar` field is mutated in place; the entry itself
    /// is heap-allocated so map re-hashes don't invalidate the
    /// `*CookieJar` we hand to ClientOptions.
    pub fn getOrLoad(
        self: *JarCache,
        allocator: std.mem.Allocator,
        io: std.Io,
        scope: []const u8,
    ) !*Entry {
        if (self.entries.get(scope)) |hit| return hit;

        // Miss — resolve the on-disk path and try to load.
        const path = try resolveScopePath(allocator, io, scope);
        errdefer if (path) |p| allocator.free(p);

        const entry = try allocator.create(Entry);
        errdefer allocator.destroy(entry);
        entry.* = .{
            .jar = CookieJar.init(allocator),
            .path = path,
        };
        if (path) |p| {
            page_mod.loadCookiesFromDisk(&entry.jar, io, p) catch |err| {
                std.log.warn("daemon: cookie jar load from {s} failed: {s}", .{ p, @errorName(err) });
            };
        }

        // Dupe the scope key — map borrows the slice; deinit frees it.
        const key_dup = try allocator.dupe(u8, scope);
        errdefer allocator.free(key_dup);
        try self.entries.put(allocator, key_dup, entry);
        return entry;
    }

    /// Write `entry`'s jar to its on-disk path (no-op when path is
    /// null). Called after each successful fetch for crash
    /// durability — the in-memory cache is the source of truth, but
    /// a hard kill of the daemon must not lose absorbed cookies.
    pub fn persist(self: *const JarCache, entry: *const Entry, io: std.Io) void {
        _ = self;
        const path = entry.path orelse return;
        page_mod.saveCookiesToDisk(&entry.jar, io, path) catch |err| {
            std.log.warn("daemon: cookie jar save to {s} failed: {s}", .{ path, @errorName(err) });
        };
    }

    /// Save+free every cached jar. Call from `run`'s defer on
    /// graceful shutdown. After this, the JarCache is empty.
    pub fn deinit(self: *JarCache, allocator: std.mem.Allocator, io: std.Io) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.persist(kv.value_ptr.*, io);
            const entry = kv.value_ptr.*;
            entry.jar.deinit();
            if (entry.path) |p| allocator.free(p);
            allocator.destroy(entry);
            allocator.free(kv.key_ptr.*);
        }
        self.entries.deinit(allocator);
    }
};

fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    should_exit: *bool,
    jar_cache: *JarCache,
) !void {
    const read_buf = try allocator.alloc(u8, READ_BUFFER_BYTES);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, WRITE_BUFFER_BYTES);
    defer allocator.free(write_buf);

    var net_reader = stream.reader(io, read_buf);
    var net_writer = stream.writer(io, write_buf);

    // Adapt std.Io.Reader/Writer to the shape jsonrpc's anytype helpers
    // expect: readUntilDelimiter / readNoEof on the reader, print /
    // writeAll on the writer. Both shims hold a single pointer so they
    // are cheap and self-contained.
    var rshim: ReaderShim = .{ .src = &net_reader.interface };
    var wshim: WriterShim = .{ .dst = &net_writer.interface };

    const body = jsonrpc.readFrame(&rshim, allocator, MAX_BODY_BYTES) catch |err| {
        log("awrd: readFrame error: {t}", .{err});
        return;
    };
    defer allocator.free(body);

    var req = jsonrpc.parseRequest(allocator, body) catch |err| {
        log("awrd: parseRequest error: {t}", .{err});
        try jsonrpc.writeError(&wshim, allocator, "null", .parse_error, "invalid request");
        try net_writer.interface.flush();
        return;
    };
    defer req.deinit();

    const method = req.method() orelse "<missing>";
    const id_json = try jsonrpc.idToJson(allocator, req.id());
    defer allocator.free(id_json);

    if (std.mem.eql(u8, method, "ping")) {
        const result = try std.fmt.allocPrint(
            allocator,
            "{{\"value\":\"pong\",\"version\":\"0.0.{s}\"}}",
            .{build_opts.git_hash},
        );
        defer allocator.free(result);
        try jsonrpc.writeSuccess(&wshim, allocator, id_json, result);
    } else if (std.mem.eql(u8, method, "shutdown")) {
        try jsonrpc.writeSuccess(&wshim, allocator, id_json, "\"shutting down\"");
        should_exit.* = true;
    } else if (std.mem.eql(u8, method, "fetch")) {
        // T-49: borrow the per-scope jar from the daemon's
        // process-wide cache so cookies set in fetch N are visible
        // in fetch N+1 without a disk round-trip. Persistence after
        // each fetch is still done for crash durability (see
        // handleFetch's post-fetch JarCache.persist call).
        handleFetch(allocator, io, &req, id_json, &wshim, jar_cache) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "{t}", .{err});
            defer allocator.free(msg);
            try jsonrpc.writeError(&wshim, allocator, id_json, .internal_error, msg);
        };
    } else {
        try jsonrpc.writeError(&wshim, allocator, id_json, .method_not_found, method);
    }
    try net_writer.interface.flush();
}

/// Handle the `fetch` method: parse params (url, optional method,
/// optional body), create a fresh Page, navigate, build the spec
/// §2.3 result envelope. Caller has already serialized the request
/// id; we own the response body.
fn handleFetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    req: *const jsonrpc.Request,
    id_json: []const u8,
    wshim: *WriterShim,
    jar_cache: *JarCache,
) !void {
    const params_val = req.params() orelse return error.MissingParams;
    const params_obj = switch (params_val) {
        .object => |o| o,
        else => return error.InvalidParams,
    };

    const url_val = params_obj.get("url") orelse return error.MissingUrl;
    const url = switch (url_val) {
        .string => |s| s,
        else => return error.InvalidUrl,
    };

    // Optional method param. Default GET. Only GET / POST are
    // supported per agent-browser.md §2.
    var is_post = false;
    if (params_obj.get("method")) |mv| switch (mv) {
        .string => |s| {
            if (std.ascii.eqlIgnoreCase(s, "POST")) {
                is_post = true;
            } else if (!std.ascii.eqlIgnoreCase(s, "GET")) {
                return error.UnsupportedMethod;
            }
        },
        else => return error.InvalidMethod,
    };

    var body_opt: ?[]const u8 = null;
    if (params_obj.get("body")) |bv| switch (bv) {
        .string => |s| body_opt = s,
        .null => {},
        else => return error.InvalidBody,
    };

    // Optional cookie_scope param (spec §2.4). Default "default".
    // Validate it's safe as a filename component — no slashes, no
    // `..`, length-bounded — so a malicious peer can't escape the
    // cookies/ subdirectory by passing `cookie_scope: "../../etc"`.
    var scope: []const u8 = "default";
    if (params_obj.get("cookie_scope")) |sv| switch (sv) {
        .string => |s| {
            if (!isValidScopeName(s)) return error.InvalidCookieScope;
            scope = s;
        },
        .null => {},
        else => return error.InvalidCookieScope,
    };

    // Borrow the scope's jar from the daemon's in-memory cache.
    // First touch loads from disk; subsequent fetches see the
    // already-resolved jar. The Entry pointer stays stable across
    // map re-hashes (entries are heap-allocated), so the borrowed
    // *CookieJar we hand to Page is safe to use through Page.deinit.
    const entry = try jar_cache.getOrLoad(allocator, io, scope);
    var p = try page_mod.Page.initWithJar(allocator, io, &entry.jar);
    defer p.deinit();

    var result = if (is_post)
        try p.navigatePost(url, body_opt orelse "")
    else
        try p.navigate(url);
    defer result.deinit();

    // Build the result envelope per spec §2.3. Mirrors the shape
    // emitted by main.zig's default JSON path so daemon callers and
    // direct CLI users see identical fields.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '{');
    try out.appendSlice(allocator, "\"url\":");
    try writeJsonStr(&out, allocator, result.url);
    const status_str = try std.fmt.allocPrint(allocator, ",\"status\":{d}", .{result.status});
    defer allocator.free(status_str);
    try out.appendSlice(allocator, status_str);
    try out.appendSlice(allocator, ",\"title\":");
    if (result.title) |t| try writeJsonStr(&out, allocator, t) else try out.appendSlice(allocator, "null");
    try out.appendSlice(allocator, ",\"body_text\":");
    try writeJsonStr(&out, allocator, result.body_text);
    try out.appendSlice(allocator, ",\"window_data\":");
    if (result.window_data) |wd| try out.appendSlice(allocator, wd) else try out.appendSlice(allocator, "null");
    try out.appendSlice(allocator, ",\"tools\":");
    if (result.tools_json) |tj| try out.appendSlice(allocator, tj) else try out.appendSlice(allocator, "[]");
    try out.append(allocator, '}');

    try jsonrpc.writeSuccess(wshim, allocator, id_json, out.items);

    // Crash durability: write the (possibly-mutated) jar back to disk
    // after each successful fetch. The in-memory cache is the source
    // of truth for cross-request reads; disk is for surviving daemon
    // crashes. Failures are logged but non-fatal — the next request
    // still uses the in-memory state.
    jar_cache.persist(entry, io);
}

/// Append `s` as a JSON-quoted string into `list`. Mirrors the
/// minimal escaper in main.zig:writeJsonStr — kept duplicated so
/// the daemon stays free of a `main` dependency.
fn writeJsonStr(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                const esc = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
                defer allocator.free(esc);
                try list.appendSlice(allocator, esc);
            },
            else => try list.append(allocator, c),
        }
    }
    try list.append(allocator, '"');
}

// ── Reader/Writer shims for jsonrpc's anytype helpers ─────────────

const ReaderShim = struct {
    src: *std.Io.Reader,

    pub fn readUntilDelimiter(self: *ReaderShim, out: []u8, delim: u8) ![]u8 {
        // readSliceShort returns ReadFailed only — partial read is
        // signalled by n < dest.len (n=0 = EOF). We surface the EOF as
        // a partial slice (mid-line) or error.EndOfStream (start of
        // line) so jsonrpc.readFrame's framing-error branches stay
        // consistent with the http1.zig TestReader contract.
        var len: usize = 0;
        while (len < out.len) {
            var single: [1]u8 = undefined;
            const n = try self.src.readSliceShort(&single);
            if (n == 0) {
                if (len == 0) return error.EndOfStream;
                return out[0..len];
            }
            out[len] = single[0];
            len += 1;
            if (single[0] == delim) return out[0..len];
        }
        return error.StreamTooLong;
    }

    pub fn readNoEof(self: *ReaderShim, dest: []u8) !void {
        var filled: usize = 0;
        while (filled < dest.len) {
            const n = try self.src.readSliceShort(dest[filled..]);
            if (n == 0) return error.EndOfStream;
            filled += n;
        }
    }
};

const WriterShim = struct {
    dst: *std.Io.Writer,

    pub fn print(self: *WriterShim, comptime fmt: []const u8, args: anytype) !void {
        try self.dst.print(fmt, args);
    }

    pub fn writeAll(self: *WriterShim, bytes: []const u8) !void {
        try self.dst.writeAll(bytes);
    }
};

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// Resolve the per-scope cookie jar path per spec §2.4:
///   `${XDG_DATA_HOME:-$HOME/.local/share}/awr/cookies/<scope>.txt`
/// Creates the parent directory if missing. Caller owns the returned slice.
///
/// Returns `null` when neither XDG_DATA_HOME nor HOME is set —
/// fetches still work, just without cookie persistence. Mirrors the
/// graceful-degradation pattern in `util/cookie_path.zig` rather than
/// erroring loudly: a missing HOME shouldn't break `awr fetch` when
/// the user never asked for cookies in the first place.
pub fn resolveScopePath(allocator: std.mem.Allocator, io: std.Io, scope: []const u8) !?[]u8 {
    const data_dir = (try resolveDataDir(allocator)) orelse return null;
    defer allocator.free(data_dir);

    // Ensure parent dir exists. createDirPath treats existing dirs as success.
    const parent = try std.fs.path.join(allocator, &.{ data_dir, "awr", "cookies" });
    defer allocator.free(parent);
    try std.Io.Dir.cwd().createDirPath(io, parent);

    return try std.fmt.allocPrint(
        allocator,
        "{s}/awr/cookies/{s}.txt",
        .{ data_dir, scope },
    );
}

/// Reads `$XDG_DATA_HOME` or falls back to `$HOME/.local/share` per the
/// XDG Base Directory spec. Returns `null` when neither is set.
fn resolveDataDir(allocator: std.mem.Allocator) !?[]u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |xdg_raw| {
        const span = std.mem.sliceTo(xdg_raw, 0);
        if (span.len > 0) return try allocator.dupe(u8, span);
    }
    if (std.c.getenv("HOME")) |home_raw| {
        const span = std.mem.sliceTo(home_raw, 0);
        if (span.len > 0) return try std.fmt.allocPrint(allocator, "{s}/.local/share", .{span});
    }
    return null;
}

/// Reject scope names that would let a peer escape the cookies/
/// subdirectory or write through symlinks. Allowed:
///   - 1..64 chars
///   - [A-Za-z0-9._-]
///   - not "." or ".." (handled by char-set: "." alone is allowed in
///     general but length=1 with "." is intentionally permitted as a
///     valid scope name; ".." is rejected by the char-set check below).
/// Disallowed: anything with `/`, NUL, `..`-as-component-name, leading dot.
pub fn isValidScopeName(scope: []const u8) bool {
    if (scope.len == 0 or scope.len > 64) return false;
    if (scope[0] == '.') return false; // no ".", "..", or hidden-file scopes
    for (scope) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// Resolve the daemon's socket path per spec §2.1.
/// `${XDG_RUNTIME_DIR:-/tmp}/awrd-${UID}.sock`.
/// Caller owns the returned slice.
pub fn resolveSocketPath(allocator: std.mem.Allocator) ![]u8 {
    const xdg_raw = std.c.getenv("XDG_RUNTIME_DIR");
    const dir: []const u8 = if (xdg_raw != null) blk: {
        const span = std.mem.sliceTo(xdg_raw.?, 0);
        if (span.len == 0) break :blk "/tmp";
        break :blk span;
    } else "/tmp";
    const uid = std.posix.system.geteuid();
    return std.fmt.allocPrint(allocator, "{s}/awrd-{d}.sock", .{ dir, uid });
}

// ── Entry point ────────────────────────────────────────────────────

pub fn main(minimal: std.process.Init.Minimal) !void {
    comptime {
        if (!@import("builtin").link_libc)
            @compileError("awrd must be built with link_libc — std.heap.c_allocator requires libc");
    }
    // c_allocator: matches main.zig's choice and steers clear of the
    // DebugAllocator stack-trace path that crashes pre-main on 0.16.
    const alloc = std.heap.c_allocator;

    var threaded: std.Io.Threaded = .init(alloc, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const socket_path = try resolveSocketPath(alloc);
    defer alloc.free(socket_path);

    try run(alloc, io, socket_path);
}

// ── Tests ──────────────────────────────────────────────────────────

test "resolveSocketPath honors XDG_RUNTIME_DIR or /tmp default" {
    const allocator = std.testing.allocator;
    const path = try resolveSocketPath(allocator);
    defer allocator.free(path);
    // Must end with `awrd-<uid>.sock` — the uid varies, so just check
    // the prefix and suffix.
    try std.testing.expect(std.mem.indexOf(u8, path, "/awrd-") != null);
    try std.testing.expect(std.mem.endsWith(u8, path, ".sock"));
}

test "isValidScopeName accepts plain alnum + ._-" {
    try std.testing.expect(isValidScopeName("default"));
    try std.testing.expect(isValidScopeName("a"));
    try std.testing.expect(isValidScopeName("project-1"));
    try std.testing.expect(isValidScopeName("my_scope.v2"));
    try std.testing.expect(isValidScopeName("0123456789abcdef"));
}

test "isValidScopeName rejects path-traversal and reserved names" {
    try std.testing.expect(!isValidScopeName(""));
    try std.testing.expect(!isValidScopeName("."));
    try std.testing.expect(!isValidScopeName(".."));
    try std.testing.expect(!isValidScopeName(".hidden"));
    try std.testing.expect(!isValidScopeName("foo/bar"));
    try std.testing.expect(!isValidScopeName("foo\x00"));
    try std.testing.expect(!isValidScopeName("with space"));
    // 65-char overlong scope is rejected.
    try std.testing.expect(!isValidScopeName("a" ** 65));
}

test "resolveScopePath uses XDG_DATA_HOME when set" {
    // We can't safely setenv inside the test (libc setenv leaks across
    // tests on some platforms), so this test only verifies the shape
    // when env vars are present. The resolver picks XDG_DATA_HOME first,
    // then HOME. We exercise the HOME path via integration tests where
    // we can fully control the env.
    const allocator = std.testing.allocator;

    // Use whatever env the test runner provides; just assert the
    // returned path ends with the expected suffix and includes the
    // scope.
    var page_dir = std.Io.Dir.cwd();
    _ = &page_dir;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path_opt = try resolveScopePath(allocator, io, "test-scope");
    // Without HOME / XDG_DATA_HOME the resolver returns null — we
    // exercise that path through integration tests where we control env.
    const path = path_opt orelse return;
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/awr/cookies/test-scope.txt"));
}
