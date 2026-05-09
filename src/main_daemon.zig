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

    log("awrd: listening on {s} version=0.0.{s}", .{ socket_path, build_opts.git_hash });

    var should_exit = false;
    while (!should_exit) {
        var stream = server.accept(io) catch |err| {
            log("awrd: accept failed: {t}", .{err});
            continue;
        };
        defer stream.close(io);

        handleConnection(allocator, io, &stream, &should_exit) catch |err| {
            log("awrd: connection error: {t}", .{err});
        };
    }
    log("awrd: shutdown complete", .{});
}

fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    should_exit: *bool,
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
        // Slice-3: per-request fresh Page wired to a scope-specific
        // on-disk jar at $XDG_DATA_HOME/awr/cookies/<scope>.txt per
        // spec/subspecs/daemon-mode.md §2.4. In-memory jar caching
        // across requests (so a cookie set in fetch N is visible in
        // fetch N+1 before disk writeback) is a later slice — today
        // the disk file IS the cache, which round-trips correctly
        // across requests but pays a load+save per fetch.
        handleFetch(allocator, io, &req, id_json, &wshim) catch |err| {
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

    // Resolve scope-specific jar path. Null when no HOME/XDG_DATA_HOME
    // in env — Page.initWithJarPath treats null as "no persistence",
    // matching the in-process Page.init contract. On non-null success,
    // Page takes ownership and frees on deinit.
    const jar_path = try resolveScopePath(allocator, io, scope);
    var p = try page_mod.Page.initWithJarPath(allocator, io, jar_path);
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
