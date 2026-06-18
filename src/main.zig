const std = @import("std");
const build_opts = @import("build_opts");
const page_mod = @import("page");
const mock_mod = @import("mock.zig");
const mcp_stdio = @import("mcp_stdio.zig");
const browser_mod = @import("browser.zig");
const session_import = @import("session_import.zig");
const bookmarks_mod = @import("bookmarks.zig");
const telemetry = @import("telemetry");
const image_protocol = @import("image_protocol");
const image_pipeline = @import("image_pipeline");

/// Wall-clock millis without the `Io` capability detour. See
/// `src/util/time.zig` for the rationale; this duplicate avoids
/// re-importing the file from main (which would create a module
/// conflict with `page`'s import).
fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Append `s` URL-encoded into `buf` per `application/x-www-form-urlencoded`.
/// Mirrors browser.zig:appendUrlEncoded — kept duplicated here rather than
/// exported because main and browser are different module roots.
fn appendUrlEncoded(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try buf.append(alloc, c),
            ' ' => try buf.append(alloc, '+'),
            else => {
                try buf.append(alloc, '%');
                const hex = try std.fmt.allocPrint(alloc, "{X:0>2}", .{c});
                defer alloc.free(hex);
                try buf.appendSlice(alloc, hex);
            },
        }
    }
}

/// Load a JSON body for `awr post --json <source>`. Source is one of:
///   - `-`           → read all of stdin
///   - `@path`       → read file at `path`
///   - any other     → treat as inline JSON bytes (duped so caller can free)
///
/// Bytes are validated with `std.json.parseFromSlice` before return; on parse
/// failure the function writes a diagnostic to stdout and exits the process
/// (mirrors the existing `each field arg must be name=value` error path so
/// scripted callers see a single failure shape). The returned slice is always
/// owned by the caller and must be freed with `alloc`.
fn loadJsonBody(alloc: std.mem.Allocator, io: std.Io, source: []const u8) ![]u8 {
    var bytes: []u8 = undefined;
    if (std.mem.eql(u8, source, "-")) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        const stdin = std.Io.File.stdin();
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.system.read(stdin.handle, &chunk, chunk.len);
            if (n <= 0) break;
            try buf.appendSlice(alloc, chunk[0..@intCast(n)]);
        }
        bytes = try alloc.dupe(u8, buf.items);
    } else if (source.len > 1 and source[0] == '@') {
        const path = source[1..];
        bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024)) catch |err| {
            const msg = try std.fmt.allocPrint(alloc, "awr post: --json @{s}: {s}\n", .{ path, @errorName(err) });
            defer alloc.free(msg);
            try stdoutWrite(io, msg);
            std.process.exit(1);
        };
    } else {
        bytes = try alloc.dupe(u8, source);
    }
    errdefer alloc.free(bytes);

    // Validate. Parse into a Value tree, then immediately discard — we send
    // the original bytes verbatim (preserves key order, number precision,
    // whitespace intent). Catches typos locally instead of letting the server
    // surface them as 400s.
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "awr post: --json body is not valid JSON: {s}\n", .{@errorName(err)});
        defer alloc.free(msg);
        try stdoutWrite(io, msg);
        std.process.exit(1);
    };
    parsed.deinit();

    return bytes;
}

fn writeJsonStr(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try list.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                const esc = try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{c});
                defer alloc.free(esc);
                try list.appendSlice(alloc, esc);
            },
            else => try list.append(alloc, c),
        }
    }
    try list.append(alloc, '"');
}

/// True when AWR_DAEMON=1 is set in the environment.
fn daemonModeEnabled() bool {
    const raw = std.c.getenv("AWR_DAEMON") orelse return false;
    const span = std.mem.sliceTo(raw, 0);
    return std.mem.eql(u8, span, "1");
}

/// Resolve the cookie scope key the CLI client should send to the
/// daemon per spec/subspecs/daemon-mode.md §2.4. Resolution order:
///   1. `$AWR_COOKIE_SCOPE` (if set and non-empty) — explicit override
///   2. `sha1($PWD)[:12]` — stable per-project handle
///   3. `"default"` — last-resort fallback when $PWD can't be read
///
/// 12 hex chars = 48 bits of name-space; collision risk for a single
/// user's project list is negligible. Returning a stable hex string
/// (vs a literal $PWD) avoids leaking the working-directory path
/// through the on-disk filename.
fn resolveCookieScope(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("AWR_COOKIE_SCOPE")) |raw| {
        const span = std.mem.sliceTo(raw, 0);
        if (span.len > 0) return allocator.dupe(u8, span);
    }
    if (std.c.getenv("PWD")) |pwd_raw| {
        const pwd = std.mem.sliceTo(pwd_raw, 0);
        if (pwd.len > 0) {
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(pwd);
            var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
            hasher.final(&digest);
            // 12 hex chars = first 6 bytes of the 20-byte digest.
            return std.fmt.allocPrint(allocator, "{x}", .{digest[0..6]});
        }
    }
    return allocator.dupe(u8, "default");
}

/// Resolve the daemon's socket path per spec/subspecs/daemon-mode.md
/// §2.1. Identical to main_daemon.zig:resolveSocketPath; duplicated
/// rather than imported because main and main_daemon are different
/// executables and we don't want main to pull in the daemon module.
fn resolveDaemonSocket(allocator: std.mem.Allocator) ![]u8 {
    const xdg_raw = std.c.getenv("XDG_RUNTIME_DIR");
    const dir: []const u8 = if (xdg_raw != null) blk: {
        const span = std.mem.sliceTo(xdg_raw.?, 0);
        if (span.len == 0) break :blk "/tmp";
        break :blk span;
    } else "/tmp";
    const uid = std.posix.system.geteuid();
    return std.fmt.allocPrint(allocator, "{s}/awrd-{d}.sock", .{ dir, uid });
}

extern fn realpath(path: [*:0]const u8, resolved_path: [*]u8) ?[*:0]u8;
extern fn access(path: [*:0]const u8, mode: c_int) c_int;

fn findExecutablePath(allocator: std.mem.Allocator, args0: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, args0, '/') != null) {
        return try allocator.dupe(u8, args0);
    }

    const path_env_c = std.c.getenv("PATH") orelse return error.PathNotFound;
    const path_env = std.mem.span(path_env_c);
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const joined = try std.fs.path.join(allocator, &.{ dir, args0 });
        const joined_z = try allocator.dupeZ(u8, joined);
        defer allocator.free(joined_z);
        if (access(joined_z, 0) == 0) {
            return joined;
        }
        allocator.free(joined);
    }
    return error.ExecutableNotFound;
}

/// Resolve the path to the `awrd` binary as a sibling of our own
/// argv[0]. Both binaries ship together: an installed `awr` at
/// `/usr/local/bin/awr` finds `/usr/local/bin/awrd`; an in-tree
/// dev run from `./zig-out/bin/awr` finds `./zig-out/bin/awrd`.
/// Caller owns the returned slice. Returns null if argv[0] has no
/// directory component (shouldn't happen — Zig's argv always has
/// the full path).
fn resolveAwrdPath(allocator: std.mem.Allocator, args0: []const u8) !?[]u8 {
    const found_path = findExecutablePath(allocator, args0) catch |err| switch (err) {
        error.PathNotFound, error.ExecutableNotFound => try allocator.dupe(u8, args0),
        else => return err,
    };
    defer allocator.free(found_path);

    const found_path_z = try allocator.dupeZ(u8, found_path);
    defer allocator.free(found_path_z);

    var resolved_buf: [4096]u8 = undefined;
    const resolved_res = realpath(found_path_z, &resolved_buf);

    const real_args0 = if (resolved_res != null) blk: {
        const len = std.mem.indexOfScalar(u8, &resolved_buf, 0) orelse resolved_buf.len;
        break :blk resolved_buf[0..len];
    } else found_path;

    const dir = std.fs.path.dirname(real_args0) orelse return null;
    return try std.fmt.allocPrint(allocator, "{s}/awrd", .{dir});
}

/// Spawn awrd in detached daemon mode (double-fork + setsid). The
/// grandchild execs awrd; the immediate child exits so the
/// grandchild reparents to init/launchd. We `wait` the child here
/// (not the grandchild) so it doesn't zombie.
///
/// On success the daemon is *starting* — it may not have bound
/// the socket yet. Caller must connect-probe before sending real
/// traffic.
fn spawnDaemon(allocator: std.mem.Allocator, awrd_path: []const u8) !void {
    // Build a sentinel-terminated argv for execve.
    var path_buf: [4096]u8 = undefined;
    if (awrd_path.len + 1 > path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..awrd_path.len], awrd_path);
    path_buf[awrd_path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    const pid1 = std.posix.system.fork();
    if (pid1 < 0) return error.ForkFailed;
    if (pid1 == 0) {
        // First child — detach from controlling terminal, fork
        // again so the grandchild is parentless.
        _ = std.posix.system.setsid();
        const pid2 = std.posix.system.fork();
        if (pid2 < 0) std.posix.system._exit(1);
        if (pid2 == 0) {
            // Grandchild — exec awrd. argv must be [path, null].
            // Redirect stdin, stdout, stderr to /dev/null so we detach from the parent's pipes.
            const null_fd = std.posix.system.open(
                "/dev/null",
                .{ .ACCMODE = .RDWR },
                @as(std.posix.mode_t, 0),
            );
            if (null_fd >= 0) {
                _ = std.posix.system.dup2(null_fd, 0);
                _ = std.posix.system.dup2(null_fd, 1);
                _ = std.posix.system.dup2(null_fd, 2);
                _ = std.posix.system.close(null_fd);
            }

            // We reuse path_z as both argv[0] and the executable.
            const argv = [_:null]?[*:0]const u8{path_z};
            // execve preserves env; we want the daemon to inherit
            // XDG_RUNTIME_DIR / XDG_DATA_HOME / etc.
            // Use std.c.execvp which searches PATH if needed; we pass
            // an absolute path so PATH is irrelevant.
            _ = std.c.execve(path_z, @ptrCast(&argv), std.c.environ);
            // execve only returns on error.
            std.posix.system._exit(127);
        }
        // First child: we forked the grandchild, our work is done.
        std.posix.system._exit(0);
    }
    // Parent: reap the immediate child so it doesn't zombie.
    var status: i32 = 0;
    _ = std.posix.system.waitpid(@intCast(pid1), &status, 0);
    _ = allocator; // unused; kept for API symmetry with future
    // variants that may want to allocate buffers.
}

fn isDaemonListening(sock_path: []const u8) bool {
    const sys = struct {
        extern fn socket(domain: c_int, @"type": c_int, protocol: c_int) c_int;
        extern fn connect(socket_fd: c_int, address: *const anyopaque, address_len: c_uint) c_int;
        extern fn close(fd: c_int) c_int;
    };
    const fd = sys.socket(1, 1, 0); // AF_UNIX=1, SOCK_STREAM=1
    if (fd < 0) return false;
    defer _ = sys.close(fd);

    var addr: std.posix.sockaddr.un = .{
        .family = 1, // AF_UNIX=1
        .path = undefined,
    };
    if (sock_path.len >= addr.path.len) return false;
    @memcpy(addr.path[0..sock_path.len], sock_path);
    addr.path[sock_path.len] = 0;

    const len = @as(c_uint, @intCast(@offsetOf(std.posix.sockaddr.un, "path") + sock_path.len + 1));
    if (sys.connect(fd, &addr, len) < 0) {
        return false;
    }
    return true;
}

/// Connect-probe the daemon socket with a short retry loop. Used
/// after a spawn to wait for the daemon to bind. Returns a
/// connected stream on success; null after `total_ms` of failed
/// attempts.
fn connectWithRetry(
    io: std.Io,
    sock_path: []const u8,
    total_ms: u64,
) !?std.Io.net.Stream {
    const ua = try std.Io.net.UnixAddress.init(sock_path);
    const step_ms: u64 = 20;
    var waited: u64 = 0;
    while (waited < total_ms) {
        if (isDaemonListening(sock_path)) {
            if (ua.connect(io)) |s| return s else |_| {}
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(step_ms)), .awake) catch {};
        waited += step_ms;
    }
    return null;
}

/// Set SO_RCVTIMEO and SO_SNDTIMEO on a socket fd. Used to bound
/// the ping path (spec §2.5: "100 ms deadline immediately after
/// connect"). Best-effort — setsockopt failure is non-fatal,
/// caller falls back to whatever the socket's natural timeout is.
fn setSocketTimeoutMs(fd: std.posix.fd_t, timeout_ms: u32) void {
    const tv: std.posix.timeval = .{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    const opt = std.mem.asBytes(&tv);
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, opt) catch {};
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, opt) catch {};
}

/// Send a `ping` JSON-RPC request and return the daemon's reported
/// version (the value of `result.version`). Caller owns the
/// returned slice. Errors out if the daemon doesn't respond within
/// `total_ms` (per spec §2.5: 100ms deadline) or returns a
/// malformed envelope.
fn pingForVersion(
    alloc: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    total_ms: u32,
) ![]u8 {
    // Apply the deadline at the kernel level via setsockopt so a
    // hung daemon doesn't wedge the CLI. EAGAIN on read/write
    // surfaces as a stream error which our caller treats as
    // "respawn the daemon".
    setSocketTimeoutMs(stream.socket.handle, total_ms);

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var net_writer = stream.writer(io, &wbuf);
    var net_reader = stream.reader(io, &rbuf);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"ping\"}";
    try net_writer.interface.print(
        "Content-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    try net_writer.interface.flush();

    // Read framed response. Reuse main's frame-parsing loop shape.
    var content_length: ?usize = null;
    var line_buf: [4096]u8 = undefined;
    while (true) {
        var len: usize = 0;
        while (len < line_buf.len) {
            var single: [1]u8 = undefined;
            const n = try net_reader.interface.readSliceShort(&single);
            if (n == 0) return error.UnexpectedEof;
            line_buf[len] = single[0];
            len += 1;
            if (single[0] == '\n') break;
        }
        const line = std.mem.trimEnd(u8, line_buf[0..len], "\r\n");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    const blen = content_length orelse return error.MissingContentLength;
    const resp = try alloc.alloc(u8, blen);
    defer alloc.free(resp);
    var filled: usize = 0;
    while (filled < blen) {
        const n = try net_reader.interface.readSliceShort(resp[filled..]);
        if (n == 0) return error.UnexpectedEof;
        filled += n;
    }

    // Extract the version field. Look for "version":"...".
    const needle = "\"version\":\"";
    const start = std.mem.indexOf(u8, resp, needle) orelse return error.MalformedPing;
    const v_start = start + needle.len;
    const v_end = std.mem.indexOfScalarPos(u8, resp, v_start, '"') orelse return error.MalformedPing;
    return alloc.dupe(u8, resp[v_start..v_end]);
}

/// Send a `shutdown` JSON-RPC request to the daemon. Best-effort —
/// returns void on success, errors on transport failure. Caller
/// must close the stream after.
fn sendShutdown(io: std.Io, stream: *std.Io.net.Stream) !void {
    var wbuf: [256]u8 = undefined;
    var net_writer = stream.writer(io, &wbuf);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"shutdown\"}";
    try net_writer.interface.print(
        "Content-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    try net_writer.interface.flush();
}

/// Acquire a live, version-matched connection to the daemon. On
/// connect failure (ENOENT/ECONNREFUSED — daemon not running),
/// auto-spawn it and retry. After connect, ping for the version
/// and compare with our build_opts.git_hash; mismatch → send
/// shutdown, wait briefly, respawn.
///
/// Note on connection lifetime: the daemon serves one request per
/// connection (defer close in handleConnection). We use ONE
/// connection for the verification ping, then OPEN A FRESH one
/// for the fetch. Returning the post-ping connection would fail
/// with WriteFailed on the next write because the daemon already
/// closed it.
///
/// Errors propagate as fatal: the CLI prints a useful message and
/// exits 1 (no graceful fallback to in-process — the user
/// explicitly opted into AWR_DAEMON).
fn ensureDaemonConnected(
    alloc: std.mem.Allocator,
    io: std.Io,
    args0: []const u8,
    sock_path: []const u8,
) !std.Io.net.Stream {
    const ua = try std.Io.net.UnixAddress.init(sock_path);

    // First attempt: try connecting to an already-running daemon.
    var verified = false;
    if (isDaemonListening(sock_path)) {
        if (ua.connect(io)) |s| {
            var ping_stream = s;
            // Connected — verify the version matches our build hash.
            if (versionMatches(alloc, io, &ping_stream)) |matched| {
                ping_stream.close(io);
                if (matched) {
                    verified = true;
                } else {
                    // Mismatch — tell the daemon to shut down, then
                    // respawn ours below. Reconnect for the shutdown
                    // call (ping already consumed the prior conn).
                    if (isDaemonListening(sock_path)) {
                        if (ua.connect(io)) |s2| {
                            var sd_stream = s2;
                            sendShutdown(io, &sd_stream) catch {};
                            sd_stream.close(io);
                        } else |_| {}
                    }
                    // Wait briefly for the daemon to release the lock
                    // so our spawn can acquire it.
                    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake) catch {};
                }
            } else |_| {
                // Couldn't ping — assume the existing daemon is
                // unhealthy. Respawn.
                ping_stream.close(io);
            }
        } else |_| {}
    }

    if (!verified) {
        // Spawn awrd. The pid file's flock guarantees only one
        // daemon binds the socket even if N clients spawn in
        // parallel — losers exit 0 quickly.
        const awrd_path = (try resolveAwrdPath(alloc, args0)) orelse {
            return error.AwrdPathUnknown;
        };
        defer alloc.free(awrd_path);
        try spawnDaemon(alloc, awrd_path);

        // Probe the socket for up to 2s.
        const probe = (try connectWithRetry(io, sock_path, 2000)) orelse {
            return error.DaemonStartTimeout;
        };
        var ping_stream = probe;
        // Verify the freshly-spawned daemon's version. Mismatch
        // here is a real bug (we just spawned the binary that
        // ships with us) — surface as an error rather than
        // spinning forever.
        const ok = versionMatches(alloc, io, &ping_stream) catch |err| {
            ping_stream.close(io);
            return err;
        };
        ping_stream.close(io);
        if (!ok) return error.DaemonVersionMismatch;
    }

    // Open a fresh connection for the actual fetch. The ping
    // connection is already closed (one request per conn).
    return ua.connect(io);
}

/// Send a ping, parse the version, and compare with our own
/// build_opts.git_hash. Caller owns nothing. The caller's stream
/// is left in a usable state on a true response (caller will
/// reuse it for subsequent calls); on false the caller will
/// shutdown+respawn.
fn versionMatches(alloc: std.mem.Allocator, io: std.Io, stream: *std.Io.net.Stream) !bool {
    const v = try pingForVersion(alloc, io, stream, 100);
    defer alloc.free(v);
    // Daemon returns "0.0.<git_hash>". Strip the leading "0.0.".
    const prefix = "0.0.";
    const hash_part = if (std.mem.startsWith(u8, v, prefix)) v[prefix.len..] else v;
    return std.mem.eql(u8, hash_part, build_opts.git_hash);
}

/// AWR_DAEMON=1 path: connect to the daemon socket, send a fetch
/// request for `url`, copy the result envelope to stdout, exit.
/// Format-flag handling mirrors the in-process path so callers can
/// flip AWR_DAEMON without changing their flag set.
fn runViaDaemon(
    alloc: std.mem.Allocator,
    io: std.Io,
    args0: []const u8,
    url: []const u8,
    format_md: bool,
) !void {
    const sock_path = try resolveDaemonSocket(alloc);
    defer alloc.free(sock_path);

    // T-53: connect with auto-spawn + ping/build-hash check.
    // On ENOENT/ECONNREFUSED, double-fork awrd and retry. On
    // version mismatch, send shutdown and respawn. Returns a
    // live socket connection ready for the fetch request, or
    // an error if all retries failed.
    var stream = try ensureDaemonConnected(alloc, io, args0, sock_path);
    defer stream.close(io);

    // Cookie scope per spec §2.4 — defaults to sha1($PWD)[:12], or
    // an explicit AWR_COOKIE_SCOPE override. The daemon validates
    // the name and routes to the per-scope on-disk jar.
    const scope = try resolveCookieScope(alloc);
    defer alloc.free(scope);

    // Build the fetch JSON-RPC body. method/body still default to
    // GET / unset; subsequent slices will surface them through the
    // CLI surface. format_md is applied client-side after the
    // daemon returns the envelope.
    var req_body: std.ArrayList(u8) = .empty;
    defer req_body.deinit(alloc);
    try req_body.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"fetch\",\"params\":{\"url\":");
    try writeJsonStr(&req_body, alloc, url);
    try req_body.appendSlice(alloc, ",\"cookie_scope\":");
    try writeJsonStr(&req_body, alloc, scope);
    try req_body.appendSlice(alloc, "}}");

    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var net_reader = stream.reader(io, &rbuf);
    var net_writer = stream.writer(io, &wbuf);
    try net_writer.interface.print(
        "Content-Length: {d}\r\n\r\n{s}",
        .{ req_body.items.len, req_body.items },
    );
    try net_writer.interface.flush();

    // Read framed response. Headers up to blank line, then exactly
    // Content-Length bytes. Mirrors the parser in
    // tests/integration_runner.zig:readFrame.
    var content_length: ?usize = null;
    var line_buf: [4096]u8 = undefined;
    while (true) {
        var len: usize = 0;
        while (len < line_buf.len) {
            var single: [1]u8 = undefined;
            const n = try net_reader.interface.readSliceShort(&single);
            if (n == 0) return error.UnexpectedEof;
            line_buf[len] = single[0];
            len += 1;
            if (single[0] == '\n') break;
        }
        const line = std.mem.trimEnd(u8, line_buf[0..len], "\r\n");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    const blen = content_length orelse return error.MissingContentLength;
    const resp_body = try alloc.alloc(u8, blen);
    defer alloc.free(resp_body);
    var filled: usize = 0;
    while (filled < blen) {
        const n = try net_reader.interface.readSliceShort(resp_body[filled..]);
        if (n == 0) return error.UnexpectedEof;
        filled += n;
    }

    // Forward the daemon's envelope to stdout. The shape is
    // `{"jsonrpc":"2.0","id":1,"result":{...envelope...}}` —
    // extract `result` so callers see the same shape as the
    // in-process path. format_md is a future-work item.
    _ = format_md;
    if (extractJsonRpcResult(resp_body)) |result_slice| {
        // T-58: parse the daemon's telemetry side-channel out of
        // the envelope. Spec §2.2: CLI owns AWR_TELEMETRY emission.
        // The daemon includes per-fetch phase timings under the
        // `telemetry` key; we merge them into the local
        // SessionMetrics and emit through the existing path. The
        // user-facing stdout envelope MUST NOT include `telemetry`
        // (would be double-emission for AWR_TELEMETRY users and
        // shape-incompatible with the in-process path).
        var metrics = telemetry.SessionMetrics.init();
        metrics.url = url;
        defer telemetry.emit(&metrics, alloc, io);
        if (extractJsonField(result_slice, "telemetry")) |tel_json| {
            mergeDaemonTelemetry(&metrics, tel_json);
        }
        const stripped = try stripTelemetryField(alloc, result_slice);
        defer alloc.free(stripped);
        metrics.envelope_bytes = stripped.len + 1; // +1 for newline
        try stdoutWrite(io, stripped);
        try stdoutWrite(io, "\n");
    } else {
        // Daemon returned an error envelope — surface it verbatim
        // and exit non-zero so shell callers see the failure.
        try stdoutWrite(io, resp_body);
        try stdoutWrite(io, "\n");
        std.process.exit(1);
    }
}

/// Extract the JSON value (object, array, string, or number) for the
/// top-level field `name` from `obj`. Returns the raw byte slice of
/// the value, or null if the field is missing. Operates on the
/// daemon's well-known envelope shape — we don't pull a full JSON
/// parser into main.zig for this. Limitation: works only for
/// string-typed JSON keys with no whitespace before/after the colon
/// in the daemon's emit, which the daemon writeJsonStr guarantees.
fn extractJsonField(obj: []const u8, name: []const u8) ?[]const u8 {
    // Build a search needle: `"<name>":`.
    var needle_buf: [128]u8 = undefined;
    if (name.len + 4 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + name.len], name);
    needle_buf[1 + name.len] = '"';
    needle_buf[2 + name.len] = ':';
    const needle = needle_buf[0 .. 3 + name.len];
    const idx = std.mem.indexOf(u8, obj, needle) orelse return null;
    const i = idx + needle.len;
    if (i >= obj.len) return null;

    return readJsonValue(obj, i);
}

/// Walk a JSON value starting at `start` and return the slice
/// covering it. Handles objects, arrays, strings, numbers, true/false/null.
fn readJsonValue(obj: []const u8, start: usize) ?[]const u8 {
    var i = start;
    if (i >= obj.len) return null;
    const c0 = obj[i];
    if (c0 == '{' or c0 == '[') {
        const open = c0;
        const close: u8 = if (open == '{') '}' else ']';
        var depth: i32 = 0;
        var in_string = false;
        var escape = false;
        while (i < obj.len) : (i += 1) {
            const c = obj[i];
            if (in_string) {
                if (escape) {
                    escape = false;
                    continue;
                }
                if (c == '\\') {
                    escape = true;
                    continue;
                }
                if (c == '"') in_string = false;
                continue;
            }
            if (c == '"') {
                in_string = true;
            } else if (c == open) {
                depth += 1;
            } else if (c == close) {
                depth -= 1;
                if (depth == 0) return obj[start .. i + 1];
            }
        }
        return null;
    }
    if (c0 == '"') {
        var escape = false;
        var j = i + 1;
        while (j < obj.len) : (j += 1) {
            const c = obj[j];
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\') {
                escape = true;
                continue;
            }
            if (c == '"') return obj[start .. j + 1];
        }
        return null;
    }
    // Bare value (number/true/false/null) — read until separator.
    while (i < obj.len) : (i += 1) {
        const c = obj[i];
        if (c == ',' or c == '}' or c == ']') return obj[start..i];
    }
    return obj[start..];
}

/// Populate the CLI-side SessionMetrics from the daemon's telemetry
/// JSON object. We pluck the few keys we actually care about
/// (timings); the rest stay at defaults. The daemon's
/// SessionMetrics.writeJson uses the same field names, so mapping
/// is a direct lookup.
fn mergeDaemonTelemetry(metrics: *telemetry.SessionMetrics, tel: []const u8) void {
    setI64Field(&metrics.navigate_fetch_ms, tel, "navigate_fetch_ms");
    setI64Field(&metrics.process_html_ms, tel, "process_html_ms");
    setI64Field(&metrics.page_init_ms, tel, "page_init_ms");
    setI64Field(&metrics.json_emit_ms, tel, "json_emit_ms");
    setI64Field(&metrics.js_reset_ms, tel, "js_reset_ms");
    setI64Field(&metrics.parse_ms, tel, "parse_ms");
    setI64Field(&metrics.bridge_ms, tel, "bridge_ms");
    setI64Field(&metrics.prefetch_ms, tel, "prefetch_ms");
    setI64Field(&metrics.scripts_ms, tel, "scripts_ms");
    setI64Field(&metrics.drain_interactive_ms, tel, "drain_interactive_ms");
    setI64Field(&metrics.drain_load_ms, tel, "drain_load_ms");
    setI64Field(&metrics.extract_ms, tel, "extract_ms");
    if (extractJsonField(tel, "status")) |s| {
        metrics.status = std.fmt.parseInt(u16, s, 10) catch null;
    }
    if (extractJsonField(tel, "body_bytes")) |s| {
        metrics.body_bytes = std.fmt.parseInt(usize, s, 10) catch 0;
    }
    if (extractJsonField(tel, "ext_fetch_count")) |s| {
        metrics.ext_fetch_count = std.fmt.parseInt(u32, s, 10) catch 0;
    }
    if (extractJsonField(tel, "ext_fetch_total_ms")) |s| {
        metrics.ext_fetch_total_ms = std.fmt.parseInt(i64, s, 10) catch 0;
    }
    if (extractJsonField(tel, "ext_fetch_bytes")) |s| {
        metrics.ext_fetch_bytes = std.fmt.parseInt(usize, s, 10) catch 0;
    }
    // protocol_main is a quoted string; trim the surrounding quotes.
    if (extractJsonField(tel, "protocol_main")) |s| {
        if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
            // SessionMetrics.protocol_main expects a static-lifetime
            // slice (`pub fn tag(...)` returns `[]const u8` from
            // a comptime-known set). The daemon's wire value
            // matches that set, so we pin it to a fixed table.
            const inner = s[1 .. s.len - 1];
            if (std.mem.eql(u8, inner, "std")) {
                metrics.protocol_main = "std";
            } else if (std.mem.eql(u8, inner, "h1.1")) {
                metrics.protocol_main = "h1.1";
            } else if (std.mem.eql(u8, inner, "h2")) {
                metrics.protocol_main = "h2";
            }
        }
    }
}

fn setI64Field(slot: *i64, tel: []const u8, name: []const u8) void {
    const v = extractJsonField(tel, name) orelse return;
    slot.* = std.fmt.parseInt(i64, v, 10) catch slot.*;
}

/// Return a copy of `result` with the `,"telemetry":{...}` field
/// removed. The user-facing stdout shape mirrors the in-process
/// path, which never includes telemetry inline. Caller frees the
/// returned slice.
fn stripTelemetryField(alloc: std.mem.Allocator, result: []const u8) ![]u8 {
    const needle = ",\"telemetry\":";
    const idx = std.mem.indexOf(u8, result, needle) orelse {
        // No telemetry field — return a verbatim copy. This is the
        // pre-T-58 daemon path or a daemon error envelope.
        return alloc.dupe(u8, result);
    };
    const value_start = idx + needle.len;
    const tel_value = readJsonValue(result, value_start) orelse return alloc.dupe(u8, result);
    const value_end = value_start + tel_value.len;
    const out_len = result.len - (value_end - idx);
    var out = try alloc.alloc(u8, out_len);
    @memcpy(out[0..idx], result[0..idx]);
    @memcpy(out[idx..], result[value_end..]);
    return out;
}

/// Extract the value of the top-level `"result"` field from a
/// JSON-RPC response body. Returns null if the response is an error
/// envelope (`"error"` field present) or if `"result"` is missing.
/// Operates on the raw bytes so we don't have to pull a JSON parser
/// into main.zig — the daemon emits a stable shape we can rely on.
fn extractJsonRpcResult(resp: []const u8) ?[]const u8 {
    // If error envelope, give up.
    if (std.mem.indexOf(u8, resp, "\"error\":") != null) return null;

    const needle = "\"result\":";
    const start = std.mem.indexOf(u8, resp, needle) orelse return null;
    const v_start = start + needle.len;
    if (v_start >= resp.len) return null;

    // Walk until we close the outer JSON value of result. Track
    // brace/bracket depth ignoring depths inside strings.
    var i: usize = v_start;
    var depth: i32 = 0;
    var in_string = false;
    var escape = false;
    while (i < resp.len) : (i += 1) {
        const c = resp[i];
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\') {
                escape = true;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                depth -= 1;
                if (depth == 0) return resp[v_start .. i + 1];
                if (depth < 0) {
                    // Closed at an outer level — result is not an
                    // object/array. Return up to here.
                    return resp[v_start..i];
                }
            },
            ',' => if (depth == 0) return resp[v_start..i],
            else => {},
        }
    }
    return resp[v_start..];
}

const USAGE =
    \\AWR — CLI Browser Runtime
    \\
    \\Usage:
    \\  awr tui [<url>] [--no-js]    Open the interactive terminal browser. Without a URL,
    \\                                 starts on AWR_HOMEPAGE if set, otherwise opens with the
    \\                                 URL bar active. `awr browse` is a deprecated alias.
    \\                                 Keys (when reading a page): Tab/Shift-Tab move focus,
    \\                                   Enter activates link/submit, Space toggles
    \\                                   checkbox/radio or opens <select> picker, : URL bar
    \\                                   (↑/↓ inside cycles recent URLs, AWR_URL_HISTORY_LEN
    \\                                    sets the ring buffer size), / find, b/f back/forward,
    \\                                   r reload, c cookie inspector (in-inspector: arrows
    \\                                   move, d delete row, C clear all, q close),
    \\                                   B bookmark current page, h help (all keys), q quit.
    \\                                 --no-js disables script execution (escape hatch
    \\                                 for sites whose JS strips their own UI in a
    \\                                 non-Chromium env, e.g. Google's homepage).
    \\  awr session import <browser> [--out PATH] [--profile NAME] [--source PATH]
    \\                               Import cookies from Chrome/Firefox SQLite into a Netscape
    \\                                 cookies.txt that AWR_COOKIE_JAR can load. Browsers:
    \\                                 chrome, chromium, firefox. macOS Chrome encrypted
    \\                                 cookies are skipped (Keychain integration deferred).
    \\  awr bookmark <add|list|rm>   Manage bookmarks. `add <url> [--title=…]` appends;
    \\                                 `list` prints id<TAB>created_ts<TAB>title<TAB>url;
    \\                                 `rm <id>` removes by numeric id. Storage:
    \\                                 $XDG_DATA_HOME/awr/bookmarks.txt (or $AWR_BOOKMARKS).
    \\  awr render <url> [--width N] [--images=MODE] [--no-js]
    \\                               Load URL, print the rendered terminal text non-interactively
    \\                               --images=auto|kitty|iterm|sixel|braille|none (default: auto)
    \\  awr <url> [--format=md] [--header "Name: Value"] ...
    \\                               Load URL/path, print JSON envelope. Default body_text is plain text;
    \\                                 `--format=markdown` (or `=md`) swaps it for the Markdown extraction
    \\                                 (chrome-filtered, headings + inline links preserved) under `body_md`.
    \\                                 `--header "Name: Value"` injects a custom request header (repeatable).
    \\                                 Set `AWR_DAEMON=1` to route through `awrd` instead of running
    \\                                 the page pipeline in-process (warmer connection pool).
    \\  awr post <url> [k=v ...] [--header "Name: Value"] ...
    \\                               POST URL-encoded form fields, follow redirects, absorb cookies.
    \\                                 Set $AWR_COOKIE_JAR to persist cookies across invocations.
    \\  awr post <url> --json <body>|@file|- [--header "Name: Value"] ...
    \\                               POST with Content-Type: application/json. <body> is inline JSON,
    \\                                 @path reads a file, `-` reads stdin. Body is validated locally
    \\                                 before send. Mutually exclusive with k=v form fields.
    \\  awr submit <url> [--form=SEL] [k=v ...]
    \\                               Load page, find <form>, merge user fields with hidden inputs (CSRF),
    \\                                 POST to the form's action. --form selects by #id (default: first form)
    \\  awr extract <url>            Load page, emit Markdown (token-friendly for LLM agents).
    \\                                 Drops nav/footer chrome, preserves headings/lists/inline links.
    \\  awr cookies [show|clear]     Show or clear the persistent cookie jar (uses $AWR_COOKIE_JAR).
    \\  awr tools <url>              Load URL/path, print the JSON array of registered WebMCP tools
    \\  awr call <url> <name> <json> Load URL/path, invoke tool <name> with <json> args, print result envelope
    \\  awr mock [--port N]          Serve experiments/ over HTTP (default: 127.0.0.1:7777)
    \\  awr --version                Print version and exit
    \\
    \\<url> may be an http(s):// URL, a file:// URL, or a local filesystem path.
    \\
;

fn stdoutWrite(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

/// T2.4: parse --code-style=auto|none|tag from CLI.
fn parseCodeStyle(s: []const u8) ?page_mod.CodeStyle {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "tag")) return .tag;
    return null;
}

fn describeLoadError(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidUrl => "invalid URL",
        error.DnsResolutionFailed => "DNS resolution failed",
        error.ConnectionFailed => "connection failed",
        error.TlsNotAvailable => "TLS setup or handshake failed",
        error.TooManyRedirects => "too many redirects",
        error.FileNotFound => "file not found",
        error.AccessDenied => "access denied",
        error.NotDir => "path contains a non-directory segment",
        error.IsDir => "path points to a directory, not a file",
        error.NameTooLong => "path is too long",
        error.FileTooBig => "file exceeds the supported size limit",
        error.NoSpaceLeft => "out of disk space",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
}

fn fatalLoadError(action: []const u8, location: []const u8, err: anyerror) noreturn {
    std.process.fatal("error {s} {s}: {s} ({s})", .{
        action,
        location,
        describeLoadError(err),
        @errorName(err),
    });
}

/// Telemetry-aware variant of `fatalLoadError`. Records the error
/// onto the session metrics and emits before calling fatal, so failed
/// fetches show up in aggregate logs alongside successful ones.
/// std.process.fatal calls posix.exit which does NOT run deferred
/// cleanup, including the deferred telemetry.emit at the top of
/// main — without this manual emit, the error path would be invisible
/// to telemetry.
fn fatalLoadErrorWithMetrics(
    metrics: *telemetry.SessionMetrics,
    alloc: std.mem.Allocator,
    io: std.Io,
    action: []const u8,
    location: []const u8,
    err: anyerror,
) noreturn {
    metrics.error_kind = @errorName(err);
    metrics.error_message = describeLoadError(err);
    telemetry.emit(metrics, alloc, io);
    fatalLoadError(action, location, err);
}

/// Detect whether `awr call` returned the error envelope shape
/// `{ "ok": false, ... }` (with or without spaces after the colon).
fn isFailedCallEnvelope(out: []const u8) bool {
    const s = std.mem.trim(u8, out, " \t\r\n");
    const tight = std.mem.indexOf(u8, s, "\"ok\":false");
    if (tight) |i| return i < 24;
    const spaced = std.mem.indexOf(u8, s, "\"ok\": false");
    if (spaced) |i| return i < 24;
    return false;
}

/// Parse a `--header` value into a name/value pair.
/// Accepts `"Name: Value"` or `"Name:Value"` (first `:` is the separator).
/// Returns null when the string has no `:`.
fn parseHeaderArg(s: []const u8) ?std.http.Header {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    const name = s[0..colon];
    const value_raw = s[colon + 1 ..];
    const value = std.mem.trimStart(u8, value_raw, " ");
    return .{ .name = name, .value = value };
}

/// Load a page from either an http(s):// URL or a local file path.
/// The returned PageResult is owned by the caller.
fn loadPage(
    p: *page_mod.Page,
    alloc: std.mem.Allocator,
    io: std.Io,
    location: []const u8,
) !page_mod.PageResult {
    if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) {
        return p.navigateSmart(location);
    }

    const path: []const u8 = if (std.mem.startsWith(u8, location, "file://"))
        location[7..]
    else
        location;

    const html = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024));
    defer alloc.free(html);

    const synthetic_url = if (std.mem.startsWith(u8, location, "file://"))
        try alloc.dupe(u8, location)
    else
        try std.fmt.allocPrint(alloc, "file://{s}", .{path});
    defer alloc.free(synthetic_url);

    return p.processHtml(synthetic_url, 200, html);
}

// We accept `Init.Minimal` instead of the richer `Init` so that Zig's
// startup code in `std/start.zig` skips its own `DebugAllocator` setup.
// That allocator captures a stack trace on every allocation, which in Zig
// 0.16 panics with `integer overflow` inside
// `std/debug/SelfInfo/Elf.zig:{460,472}` — the VDSO's `phdr.vaddr =
// 0xffffffffff700000` is added to `info.addr` without wrapping arithmetic.
// The buggy code path runs before `main`, so instrumenting here is too
// late; the only in-repo fix is to never take that path. Upstream needs
// `info.addr +% phdr.vaddr` on those two lines (line 497 already does
// this for the .LOAD case).
pub fn main(minimal: std.process.Init.Minimal) !void {
    comptime {
        if (!@import("builtin").link_libc)
            @compileError("awr must be built with -Dlink_libc or `exe.linkLibC()` — " ++
                "std.heap.c_allocator requires libc");
    }
    // `c_allocator` because build.zig links libc; this matches what
    // `std/start.zig` does in ReleaseSafe/Fast and keeps the CLI well away
    // from the `DebugAllocator` path above.
    const alloc = std.heap.c_allocator;

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();

    var threaded: std.Io.Threaded = .init(alloc, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const args = try minimal.args.toSlice(arena_state.allocator());

    if (args.len < 2) {
        try stdoutWrite(io, USAGE);
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
        const out = try std.fmt.allocPrint(alloc, "0.0.{s}\n", .{build_opts.git_hash});
        defer alloc.free(out);
        try stdoutWrite(io, out);
        return;
    }

    // `awr --help` / `-h` / `help` — print USAGE and exit 0.
    // Distinct from the args.len < 2 branch above, which prints USAGE and
    // exits 1 because no argument was supplied at all (error condition).
    if (std.mem.eql(u8, args[1], "--help") or
        std.mem.eql(u8, args[1], "-h") or
        std.mem.eql(u8, args[1], "help"))
    {
        try stdoutWrite(io, USAGE);
        return;
    }

    // Subcommand: awr session import <browser> [--out PATH] [--profile N] [--source PATH]
    if (std.mem.eql(u8, args[1], "session")) {
        try runSessionSubcommand(alloc, io, args);
        return;
    }

    // Subcommand: awr bookmark <add|list|rm> [...] — T-89 / Tier 2 T2.1.
    if (std.mem.eql(u8, args[1], "bookmark")) {
        try runBookmarkSubcommand(alloc, io, args);
        return;
    }

    // Subcommand: awr mock [--port N] [--root DIR]
    if (std.mem.eql(u8, args[1], "mock")) {
        var port: u16 = 7777;
        var root: []const u8 = "experiments";
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
                port = std.fmt.parseInt(u16, args[i + 1], 10) catch {
                    std.process.fatal("mock: --port expects a u16, got '{s}'", .{args[i + 1]});
                };
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--root") and i + 1 < args.len) {
                root = args[i + 1];
                i += 1;
            } else {
                std.process.fatal("mock: unknown arg '{s}'", .{args[i]});
            }
        }
        try mock_mod.run(alloc, io, "127.0.0.1", port, root);
        return;
    }

    // Subcommand: `awr tui [<url>]` (canonical) and `awr browse [<url>]` (alias).
    // T-75: `tui` is the human-facing browser command. URL is optional —
    // when omitted we fall back to `AWR_HOMEPAGE`, and finally to opening
    // with the URL bar already active so the user can type a destination.
    if (std.mem.eql(u8, args[1], "tui") or std.mem.eql(u8, args[1], "browse")) {
        const subcmd = args[1];
        var url_arg: ?[]const u8 = null;
        var disable_scripts = false;
        // T-92: --images=MODE accepts auto/kitty/iterm/sixel/braille/none,
        // mirroring `awr render`. Default `.auto` probes the terminal
        // and lands on the right protocol; `.none` skips entirely.
        var image_mode: image_protocol.Mode = .auto;
        var tui_code_line_numbers: usize = 5;
        var tui_code_style: page_mod.CodeStyle = .none;
        var ai: usize = 2;
        while (ai < args.len) : (ai += 1) {
            const arg = args[ai];
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                // §2.3 closure gate: `awr tui --help` must surface the
                // keybindings (including `h`). Print the shared USAGE block,
                // which carries the full TUI key list, and exit 0.
                try stdoutWrite(io, USAGE);
                return;
            } else if (std.mem.eql(u8, arg, "--no-js") or std.mem.eql(u8, arg, "--no-script")) {
                disable_scripts = true;
            } else if (std.mem.startsWith(u8, arg, "--images=")) {
                const value = arg["--images=".len..];
                image_mode = image_protocol.parseMode(value) orelse {
                    std.process.fatal("{s}: --images expected auto|kitty|iterm|sixel|braille|none, got '{s}'", .{ subcmd, value });
                };
            } else if (std.mem.eql(u8, arg, "--images") and ai + 1 < args.len) {
                image_mode = image_protocol.parseMode(args[ai + 1]) orelse {
                    std.process.fatal("{s}: --images expected auto|kitty|iterm|sixel|braille|none, got '{s}'", .{ subcmd, args[ai + 1] });
                };
                ai += 1;
            } else if (std.mem.startsWith(u8, arg, "--code-line-numbers=")) {
                const val = arg["--code-line-numbers=".len..];
                tui_code_line_numbers = std.fmt.parseInt(usize, val, 10) catch {
                    std.process.fatal("{s}: --code-line-numbers expects an integer, got '{s}'", .{ subcmd, val });
                };
            } else if (std.mem.startsWith(u8, arg, "--code-style=")) {
                const val = arg["--code-style=".len..];
                tui_code_style = parseCodeStyle(val) orelse {
                    std.process.fatal("{s}: --code-style expects auto|none|tag, got '{s}'", .{ subcmd, val });
                };
            } else if (std.mem.startsWith(u8, arg, "--")) {
                try stdoutWrite(io, subcmd);
                try stdoutWrite(io, ": unknown flag: ");
                try stdoutWrite(io, arg);
                try stdoutWrite(io, "\n");
                std.process.exit(1);
            } else if (url_arg == null) {
                url_arg = arg;
            } else {
                std.process.fatal("{s}: unexpected positional arg '{s}'", .{ subcmd, arg });
            }
        }

        // Homepage fallback: AWR_HOMEPAGE env var beats "blank tab".
        // The slice borrows from libc's static env block, so no free.
        if (url_arg == null) {
            if (std.c.getenv("AWR_HOMEPAGE")) |raw| {
                const slice = std.mem.span(raw);
                if (slice.len > 0) url_arg = slice;
            }
        }

        // T-92: resolve the image protocol once before entering the TUI loop.
        // Same precedence as `awr render`: stdout-is-tty check, explicit mode,
        // then env-based detection (kitty / iterm / sixel) with braille
        // fallback.
        const resolved_protocol = image_protocol.resolve(.{
            .mode = image_mode,
            .stdout_is_tty = image_protocol.stdoutIsTty(),
            .env = image_protocol.realEnvSnapshot(),
            .probe_sixel = if (image_mode == .auto) &image_protocol.probeSixel else null,
        });

        try browser_mod.runWith(alloc, io, url_arg, .{
            .disable_scripts = disable_scripts,
            .image_protocol = resolved_protocol,
            .code_line_numbers = tui_code_line_numbers,
            .code_style = tui_code_style,
        });
        return;
    }

    // Subcommand: awr render <url>
    // Non-interactive sibling of `awr browse`. Loads the URL, runs it
    // through the same renderBrowseModel pipeline the TUI uses, and prints
    // the plain rendered text + link footnotes to stdout. Useful for
    // agents, scripts, smoke tests, and CI verification of the render
    // pipeline without needing a real TTY.
    if (std.mem.eql(u8, args[1], "render")) {
        if (args.len < 3) {
            try stdoutWrite(io, "usage: awr render <url> [--width N] [--images=MODE]\n");
            std.process.exit(1);
        }
        var width: usize = 78;
        // The Mode is parsed from CLI here; the runtime Protocol resolution
        // (env + isatty + Sixel probe) is performed in the rendering path
        // (sub-step 4f) where it is consumed. Validating the flag eagerly
        // gives users an immediate error on typos.
        var image_mode: image_protocol.Mode = .auto;
        var disable_scripts = false;
        var code_line_numbers: usize = 5;
        var code_style: page_mod.CodeStyle = .none;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--width") and i + 1 < args.len) {
                width = std.fmt.parseInt(usize, args[i + 1], 10) catch {
                    std.process.fatal("render: --width expects an integer, got '{s}'", .{args[i + 1]});
                };
                i += 1;
            } else if (std.mem.startsWith(u8, args[i], "--images=")) {
                const value = args[i]["--images=".len..];
                image_mode = image_protocol.parseMode(value) orelse {
                    std.process.fatal("render: --images expects auto|kitty|iterm|sixel|braille|none, got '{s}'", .{value});
                };
            } else if (std.mem.eql(u8, args[i], "--images") and i + 1 < args.len) {
                image_mode = image_protocol.parseMode(args[i + 1]) orelse {
                    std.process.fatal("render: --images expects auto|kitty|iterm|sixel|braille|none, got '{s}'", .{args[i + 1]});
                };
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--no-js") or std.mem.eql(u8, args[i], "--no-script")) {
                disable_scripts = true;
            } else if (std.mem.startsWith(u8, args[i], "--code-line-numbers=")) {
                const val = args[i]["--code-line-numbers=".len..];
                code_line_numbers = std.fmt.parseInt(usize, val, 10) catch {
                    std.process.fatal("render: --code-line-numbers expects an integer, got '{s}'", .{val});
                };
            } else if (std.mem.startsWith(u8, args[i], "--code-style=")) {
                const val = args[i]["--code-style=".len..];
                code_style = parseCodeStyle(val) orelse {
                    std.process.fatal("render: --code-style expects auto|none|tag, got '{s}'", .{val});
                };
            } else {
                std.process.fatal("render: unknown arg '{s}'", .{args[i]});
            }
        }
        // Resolve the requested mode against the runtime environment.
        // Non-TTY stdout forces `.none` (gate 8 — `awr render | tee` must
        // stay escape-free regardless of `--images=…`). The Sixel CSI probe
        // is wired only when the user requested `auto`; explicit modes skip
        // the 50 ms latency. The resolved Protocol flows through
        // RenderOptions; sub-step 4f teaches `browser.zig:draw` to act on
        // it. Today the model layer is still text-only.
        const resolved_protocol = image_protocol.resolve(.{
            .mode = image_mode,
            .stdout_is_tty = image_protocol.stdoutIsTty(),
            .env = image_protocol.realEnvSnapshot(),
            .probe_sixel = if (image_mode == .auto) &image_protocol.probeSixel else null,
        });

        // Per-session telemetry — same pattern as the default URL path.
        // The render path emits rendered terminal text instead of a
        // JSON envelope, so `envelope_bytes` reflects screen.text.len.
        var metrics = telemetry.SessionMetrics.init();
        metrics.url = args[2];
        defer telemetry.emit(&metrics, alloc, io);

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit();
        p.metrics_sink = &metrics;
        p.disable_scripts = disable_scripts;
        var result = loadPage(&p, alloc, io, args[2]) catch |err| {
            fatalLoadErrorWithMetrics(&metrics, alloc, io, "loading", args[2], err);
        };
        defer result.deinit();

        // Build the image pipeline only when a real protocol resolved.
        // `.none` (non-TTY override or `--images=none`) skips pipeline
        // construction so we never spend time fetching images we won't
        // emit.
        var pipeline_storage: ?image_pipeline.Pipeline = null;
        defer if (pipeline_storage) |*pl| pl.deinit();
        var image_lookup_opt: ?page_mod.ImageLookup = null;
        if (resolved_protocol != .none) {
            if (image_pipeline.build(alloc, &p, args[2], resolved_protocol, .{
                .max_width_cells = @intCast(width),
            }, null)) |pl| {
                pipeline_storage = pl;
                image_lookup_opt = pipeline_storage.?.lookup();
            } else |_| {
                // Pipeline construction failed; render falls back to
                // text alt-refs. No fatal — image rendering is best-
                // effort, the page text is the primary deliverable.
            }
        }

        var screen = try p.renderBrowseModel(alloc, &result, .{
            .max_width = width,
            .ansi_colors = false,
            .show_links = true,
            // Non-interactive output: emit the References footer so the
            // inline [N] link markers have a URL list to resolve against.
            // The browse profile defaults to suppressing the footer for
            // interactive use; here we override to true.
            .show_references = true,
            .show_images = true,
            .image_protocol = resolved_protocol,
            .image_lookup = image_lookup_opt,
            .code_line_numbers = code_line_numbers,
            .code_style = code_style,
        });
        defer screen.deinit();
        try stdoutWrite(io, screen.text);
        if (screen.text.len == 0 or screen.text[screen.text.len - 1] != '\n') {
            try stdoutWrite(io, "\n");
        }
        metrics.envelope_bytes = screen.text.len;
        return;
    }

    // Subcommand: awr tools <url>
    if (std.mem.eql(u8, args[1], "tools")) {
        if (args.len < 3) {
            try stdoutWrite(io, "usage: awr tools <url>\n");
            std.process.exit(1);
        }
        var metrics = telemetry.SessionMetrics.init();
        metrics.url = args[2];
        defer telemetry.emit(&metrics, alloc, io);

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit();
        p.metrics_sink = &metrics;
        var result = loadPage(&p, alloc, io, args[2]) catch |err| {
            fatalLoadErrorWithMetrics(&metrics, alloc, io, "loading", args[2], err);
        };
        defer result.deinit();
        const tj = result.tools_json orelse "[]";
        try stdoutWrite(io, tj);
        try stdoutWrite(io, "\n");
        metrics.envelope_bytes = tj.len + 1; // +1 for newline
        return;
    }

    // Subcommand: awr call <url> <tool> <json>
    if (std.mem.eql(u8, args[1], "call")) {
        if (args.len < 5) {
            try stdoutWrite(io, "usage: awr call <url> <tool-name> <json-args>\n");
            std.process.exit(1);
        }
        var metrics = telemetry.SessionMetrics.init();
        metrics.url = args[2];
        defer telemetry.emit(&metrics, alloc, io);

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit();
        p.metrics_sink = &metrics;
        var result = loadPage(&p, alloc, io, args[2]) catch |err| {
            fatalLoadErrorWithMetrics(&metrics, alloc, io, "loading", args[2], err);
        };
        defer result.deinit();
        const out = try p.callTool(args[3], args[4]);
        defer alloc.free(out);
        try stdoutWrite(io, out);
        try stdoutWrite(io, "\n");
        metrics.envelope_bytes = out.len + 1;
        // Tool-call failures are app-level, not transport-level: the
        // page loaded fine (200) but the JS tool returned `{ok:false}`.
        // Surface this distinct from network errors via error_kind so
        // aggregate logs can split "couldn't reach the page" from
        // "the page's tool said no".
        if (isFailedCallEnvelope(out)) {
            metrics.error_kind = "ToolCallFailed";
            telemetry.emit(&metrics, alloc, io);
            std.process.exit(1);
        }
        return;
    }

    // Subcommand: awr mcp <url>
    //
    // DEFERRED track (spec/subspecs/mcp-stdio.md): a native MCP JSON-RPC
    // 2.0 server over stdin/stdout that re-exports the loaded page's
    // WebMCP tools. Wired here so the surface dispatches and is testable;
    // promoting it out of DEFERRED requires a spec/MVP.md §8 amendment.
    if (std.mem.eql(u8, args[1], "mcp")) {
        if (args.len < 3) {
            try stdoutWrite(io, "usage: awr mcp <url>\n");
            std.process.exit(1);
        }
        try mcp_stdio.serve(alloc, io, args[2]);
        return;
    }

    // Subcommand: awr post <url> [field=value ...]
    //
    // Programmatic POST with cookie support — the scriptable counterpart
    // to the TUI form-submit path. Each field=value arg is URL-encoded
    // and joined into an `application/x-www-form-urlencoded` body.
    // Cookies absorbed from the response (and any redirect chain) round-
    // trip through the page's cookie jar; combined with `AWR_COOKIE_JAR`
    // this enables cross-process sign-in flows:
    //
    //   export AWR_COOKIE_JAR=$HOME/.local/state/awr/cookies.txt
    //   awr post   https://site/login user=alice password=hunter2
    //   awr        https://site/dashboard   # carries the session cookie
    //
    // Output is the same JSON envelope as the default fetch path; the
    // status / url / body_text reflect the post-redirect final response.
    if (std.mem.eql(u8, args[1], "post")) {
        if (args.len < 3) {
            try stdoutWrite(io, "usage: awr post <url> [--json <body>|@file|-] [field=value ...]\n");
            std.process.exit(1);
        }
        const url = args[2];

        // Pre-scan args[3..] for --json and --header. Supports both
        // `--json X` / `--json=X` and `--header "Name: Value"` /
        // `--header=Name:Value` forms. --json and k=v form fields are
        // mutually exclusive; --header can accompany either.
        var json_source: ?[]const u8 = null;
        var has_positional = false;
        var post_extra_headers: std.ArrayList(std.http.Header) = .empty;
        defer post_extra_headers.deinit(alloc);
        {
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                const a = args[i];
                if (std.mem.eql(u8, a, "--json")) {
                    if (i + 1 >= args.len) {
                        try stdoutWrite(io, "awr post: --json requires a value (inline JSON, @file, or -)\n");
                        std.process.exit(1);
                    }
                    json_source = args[i + 1];
                    i += 1;
                } else if (std.mem.startsWith(u8, a, "--json=")) {
                    json_source = a["--json=".len..];
                } else if (std.mem.eql(u8, a, "--header")) {
                    if (i + 1 >= args.len) {
                        try stdoutWrite(io, "awr post: --header requires a value (e.g. \"Authorization: Bearer tok\")\n");
                        std.process.exit(1);
                    }
                    i += 1;
                    const hdr = parseHeaderArg(args[i]) orelse {
                        try stdoutWrite(io, "awr post: --header value must contain ':' separating name and value\n");
                        std.process.exit(1);
                    };
                    try post_extra_headers.append(alloc, hdr);
                } else if (std.mem.startsWith(u8, a, "--header=")) {
                    const hdr = parseHeaderArg(a["--header=".len..]) orelse {
                        try stdoutWrite(io, "awr post: --header value must contain ':' separating name and value\n");
                        std.process.exit(1);
                    };
                    try post_extra_headers.append(alloc, hdr);
                } else {
                    has_positional = true;
                }
            }
        }
        if (json_source != null and has_positional) {
            try stdoutWrite(io, "awr post: --json is mutually exclusive with `name=value` fields\n");
            std.process.exit(1);
        }

        // Build the body: JSON path loads/validates via loadJsonBody; form
        // path URL-encodes each `name=value` arg.
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);
        var owned_json: ?[]u8 = null;
        defer if (owned_json) |b| alloc.free(b);
        var body_bytes: []const u8 = "";
        var content_type: ?[]const u8 = null;

        if (json_source) |src| {
            owned_json = try loadJsonBody(alloc, io, src);
            body_bytes = owned_json.?;
            content_type = "application/json";
        } else {
            var first = true;
            var fi: usize = 3;
            while (fi < args.len) : (fi += 1) {
                const pair = args[fi];
                // Skip --json, --json=X, --header, --header=X and their values.
                if (std.mem.eql(u8, pair, "--json") or std.mem.eql(u8, pair, "--header")) {
                    fi += 1;
                    continue;
                }
                if (std.mem.startsWith(u8, pair, "--json=") or std.mem.startsWith(u8, pair, "--header=")) continue;
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
                    try stdoutWrite(io, "awr post: each field arg must be `name=value`\n");
                    std.process.exit(1);
                };
                if (!first) try body.append(alloc, '&');
                first = false;
                try appendUrlEncoded(alloc, &body, pair[0..eq]);
                try body.append(alloc, '=');
                try appendUrlEncoded(alloc, &body, pair[eq + 1 ..]);
            }
            body_bytes = body.items;
        }

        var metrics = telemetry.SessionMetrics.init();
        metrics.url = url;
        defer telemetry.emit(&metrics, alloc, io);

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit();
        p.metrics_sink = &metrics;
        if (post_extra_headers.items.len > 0) {
            p.client.options.extra_request_headers = post_extra_headers.items;
        }

        var result = (if (content_type) |ct|
            p.navigatePostWithContentType(url, body_bytes, ct)
        else
            p.navigatePost(url, body_bytes)) catch |err| {
            fatalLoadErrorWithMetrics(&metrics, alloc, io, "posting", url, err);
        };
        defer result.deinit();

        // Same JSON envelope as the default path. Reuses the writeJsonStr
        // helper at the top of this file.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.append(alloc, '{');
        try out.appendSlice(alloc, "\"url\":");
        try writeJsonStr(&out, alloc, result.url);
        const status_str = try std.fmt.allocPrint(alloc, ",\"status\":{d}", .{result.status});
        defer alloc.free(status_str);
        try out.appendSlice(alloc, status_str);
        try out.appendSlice(alloc, ",\"title\":");
        if (result.title) |t| try writeJsonStr(&out, alloc, t) else try out.appendSlice(alloc, "null");
        try out.appendSlice(alloc, ",\"body_text\":");
        try writeJsonStr(&out, alloc, result.body_text);
        try out.appendSlice(alloc, ",\"window_data\":");
        if (result.window_data) |wd| try out.appendSlice(alloc, wd) else try out.appendSlice(alloc, "null");
        try out.appendSlice(alloc, ",\"tools\":");
        if (result.tools_json) |tj| try out.appendSlice(alloc, tj) else try out.appendSlice(alloc, "[]");
        try out.appendSlice(alloc, "}\n");
        try stdoutWrite(io, out.items);
        metrics.envelope_bytes = out.items.len;
        return;
    }

    // Subcommand: awr cookies [show|clear]
    //
    // Inspect or wipe the persistent cookie jar at `$AWR_COOKIE_JAR`.
    // Useful for debugging sign-in flows ("did the session cookie get
    // absorbed?") and for forced logouts ("clear and start fresh").
    //
    // No subcommand or `show`: print one cookie per line in the format
    //   <domain><TAB><path><TAB><name>=<value><TAB>expires=<unix|session>
    // with HttpOnly_ prefix on the domain when the cookie is HttpOnly.
    //
    // `clear`: empties the in-memory jar and writes an empty jar file.
    if (std.mem.eql(u8, args[1], "cookies")) {
        const sub = if (args.len >= 3) args[2] else "show";
        if (!std.mem.eql(u8, sub, "show") and !std.mem.eql(u8, sub, "clear")) {
            try stdoutWrite(io, "usage: awr cookies [show|clear]\n");
            std.process.exit(1);
        }

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit(); // saveCookiesToDisk runs here for clear path

        if (std.mem.eql(u8, sub, "clear")) {
            // Empty the jar in memory; deinit will persist the empty
            // file to disk if AWR_COOKIE_JAR is set.
            for (p.client.cookies.cookies.items) |*c| c.deinit(p.client.cookies.allocator);
            p.client.cookies.cookies.clearAndFree(p.client.cookies.allocator);
            try stdoutWrite(io, "cleared.\n");
            return;
        }

        // show: emit a tab-separated table.
        if (p.client.cookies.cookies.items.len == 0) {
            try stdoutWrite(io, "(empty)\n");
            return;
        }
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        for (p.client.cookies.cookies.items) |c| {
            line.clearRetainingCapacity();
            if (c.http_only) try line.appendSlice(alloc, "HttpOnly_");
            try line.appendSlice(alloc, c.domain);
            try line.append(alloc, '\t');
            try line.appendSlice(alloc, c.path);
            try line.append(alloc, '\t');
            try line.appendSlice(alloc, c.name);
            try line.append(alloc, '=');
            try line.appendSlice(alloc, c.value);
            try line.append(alloc, '\t');
            if (c.expires) |exp| {
                const exp_str = try std.fmt.allocPrint(alloc, "expires={d}", .{exp});
                defer alloc.free(exp_str);
                try line.appendSlice(alloc, exp_str);
            } else {
                try line.appendSlice(alloc, "expires=session");
            }
            try line.append(alloc, '\n');
            try stdoutWrite(io, line.items);
        }
        return;
    }

    // Subcommand: awr extract <url>
    //
    // Token-friendly Markdown output for LLM/agent consumption. Drops
    // nav/footer/aside chrome (via browse_heuristics), preserves
    // headings, lists, blockquotes, inline `[text](url)` links, code
    // blocks, and images. Typical 30–40% smaller than the default
    // body_text for content-rich pages, with structure preserved.
    //
    //   awr extract https://en.wikipedia.org/wiki/Web_browser > page.md
    //
    // Output is raw Markdown to stdout (no JSON wrapping). Pair with
    // `awr submit` for an authed-page reading flow:
    //
    //   awr submit https://site/login user=alice password=hunter2
    //   awr extract https://site/dashboard
    if (std.mem.eql(u8, args[1], "extract")) {
        if (args.len < 3) {
            try stdoutWrite(io, "usage: awr extract <url>\n");
            std.process.exit(1);
        }
        const url = args[2];
        var metrics = telemetry.SessionMetrics.init();
        metrics.url = url;
        defer telemetry.emit(&metrics, alloc, io);

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit();
        p.metrics_sink = &metrics;

        var result = loadPage(&p, alloc, io, url) catch |err| {
            fatalLoadErrorWithMetrics(&metrics, alloc, io, "loading", url, err);
        };
        defer result.deinit();

        const md = try p.extractMarkdown(alloc);
        defer alloc.free(md);
        try stdoutWrite(io, md);
        if (md.len == 0 or md[md.len - 1] != '\n') try stdoutWrite(io, "\n");
        metrics.envelope_bytes = md.len;
        return;
    }

    // Subcommand: awr submit <page-url> [--form=SELECTOR] [field=value ...]
    //
    // Single-shot form submit: load the page, find the form (default:
    // first <form>; --form=#id picks by selector), merge user-provided
    // field=value overrides with the form's own attribute values
    // (hidden inputs, CSRF tokens, pre-populated text), POST to the
    // form's resolved action.
    //
    // Replaces the awkward two-step pattern of `awr <login-url>` →
    // grep CSRF token → `awr post <action> csrf=... user=... password=...`.
    //
    //   export AWR_COOKIE_JAR=$HOME/.local/state/awr/cookies.txt
    //   awr submit https://site/login user=alice password=hunter2
    //
    // Output is the same JSON envelope as the default fetch path, with
    // status / url / title / body_text reflecting the post-redirect
    // final response.
    if (std.mem.eql(u8, args[1], "submit")) {
        if (args.len < 3) {
            try stdoutWrite(io, "usage: awr submit <url> [--form=SELECTOR] [field=value ...]\n");
            std.process.exit(1);
        }
        const url = args[2];

        // Parse remaining args: --form=SEL is a flag; everything else is field=value.
        var form_selector: ?[]const u8 = null;
        var overrides: std.ArrayList(page_mod.Page.FieldOverride) = .empty;
        defer overrides.deinit(alloc);
        for (args[3..]) |arg| {
            if (std.mem.startsWith(u8, arg, "--form=")) {
                form_selector = arg["--form=".len..];
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, arg, '=') orelse {
                try stdoutWrite(io, "awr submit: each field arg must be `name=value` (or --form=SEL)\n");
                std.process.exit(1);
            };
            try overrides.append(alloc, .{ .name = arg[0..eq], .value = arg[eq + 1 ..] });
        }

        var metrics = telemetry.SessionMetrics.init();
        metrics.url = url;
        defer telemetry.emit(&metrics, alloc, io);

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit();
        p.metrics_sink = &metrics;

        // Step 1: load the page so the DOM is populated and any cookies
        // set on this response (server-rotated CSRF) are absorbed.
        var get_result = loadPage(&p, alloc, io, url) catch |err| {
            fatalLoadErrorWithMetrics(&metrics, alloc, io, "loading", url, err);
        };
        defer get_result.deinit();

        // Step 2: gather form fields → (target_url, body, method).
        var sub = p.gatherFormSubmission(get_result.url, form_selector, overrides.items, alloc) catch |err| {
            const msg = switch (err) {
                error.NoCurrentDocument => "awr submit: page failed to parse",
                error.FormNotFound => "awr submit: --form selector matched no form",
                error.NoFormFound => "awr submit: page contains no <form> element",
                else => "awr submit: failed to gather form submission",
            };
            try stdoutWrite(io, msg);
            try stdoutWrite(io, "\n");
            std.process.exit(1);
        };
        defer page_mod.Page.freeFormSubmission(alloc, &sub);

        // Step 3: submit. POST through navigatePost; for GET, append body
        // as query string and load normally.
        var result: page_mod.PageResult = if (sub.method == .POST)
            p.navigatePost(sub.target_url, sub.body) catch |err| {
                fatalLoadErrorWithMetrics(&metrics, alloc, io, "submitting", sub.target_url, err);
            }
        else blk: {
            // GET: append body as query string with `?` or `&` joiner.
            const has_q = std.mem.indexOfScalar(u8, sub.target_url, '?') != null;
            const sep: u8 = if (has_q) '&' else '?';
            const full_url = if (sub.body.len == 0)
                try alloc.dupe(u8, sub.target_url)
            else
                try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{ sub.target_url, sep, sub.body });
            defer alloc.free(full_url);
            break :blk loadPage(&p, alloc, io, full_url) catch |err| {
                fatalLoadErrorWithMetrics(&metrics, alloc, io, "submitting", full_url, err);
            };
        };
        defer result.deinit();

        // Same JSON envelope as the default + post paths.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.append(alloc, '{');
        try out.appendSlice(alloc, "\"url\":");
        try writeJsonStr(&out, alloc, result.url);
        const status_str = try std.fmt.allocPrint(alloc, ",\"status\":{d}", .{result.status});
        defer alloc.free(status_str);
        try out.appendSlice(alloc, status_str);
        try out.appendSlice(alloc, ",\"title\":");
        if (result.title) |t| try writeJsonStr(&out, alloc, t) else try out.appendSlice(alloc, "null");
        try out.appendSlice(alloc, ",\"body_text\":");
        try writeJsonStr(&out, alloc, result.body_text);
        try out.appendSlice(alloc, ",\"window_data\":");
        if (result.window_data) |wd| try out.appendSlice(alloc, wd) else try out.appendSlice(alloc, "null");
        try out.appendSlice(alloc, ",\"tools\":");
        if (result.tools_json) |tj| try out.appendSlice(alloc, tj) else try out.appendSlice(alloc, "[]");
        try out.appendSlice(alloc, "}\n");
        try stdoutWrite(io, out.items);
        metrics.envelope_bytes = out.items.len;
        return;
    }

    // Default: treat arg as a URL/path and print the full JSON envelope.
    //
    // Optional `--format=markdown` flag swaps the `body_text` field for
    // the Markdown extraction (chrome-filtered, headings/lists/inline
    // links preserved — same shape as `awr extract` but inside the
    // existing JSON envelope so JSON-aware callers don't have to switch
    // subcommands). Default `--format=json` keeps prior behavior.
    var format_md = false;
    var disable_scripts = false;
    var url_arg: ?[]const u8 = null;
    var fetch_extra_headers: std.ArrayList(std.http.Header) = .empty;
    defer fetch_extra_headers.deinit(alloc);
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--format=markdown") or std.mem.eql(u8, arg, "--format=md")) {
                format_md = true;
            } else if (std.mem.eql(u8, arg, "--format=json")) {
                format_md = false;
            } else if (std.mem.eql(u8, arg, "--no-js") or std.mem.eql(u8, arg, "--no-script")) {
                disable_scripts = true;
            } else if (std.mem.eql(u8, arg, "--header")) {
                if (i + 1 >= args.len) {
                    try stdoutWrite(io, "awr: --header requires a value (e.g. \"Authorization: Bearer tok\")\n");
                    std.process.exit(1);
                }
                i += 1;
                const hdr = parseHeaderArg(args[i]) orelse {
                    try stdoutWrite(io, "awr: --header value must contain ':' separating name and value\n");
                    std.process.exit(1);
                };
                try fetch_extra_headers.append(alloc, hdr);
            } else if (std.mem.startsWith(u8, arg, "--header=")) {
                const hdr = parseHeaderArg(arg["--header=".len..]) orelse {
                    try stdoutWrite(io, "awr: --header value must contain ':' separating name and value\n");
                    std.process.exit(1);
                };
                try fetch_extra_headers.append(alloc, hdr);
            } else if (std.mem.startsWith(u8, arg, "--")) {
                try stdoutWrite(io, "awr: unknown flag: ");
                try stdoutWrite(io, arg);
                try stdoutWrite(io, "\n");
                std.process.exit(1);
            } else if (url_arg == null) {
                url_arg = arg;
            } else {
                try stdoutWrite(io, "awr: unexpected positional arg: ");
                try stdoutWrite(io, arg);
                try stdoutWrite(io, "\n");
                std.process.exit(1);
            }
        }
    }
    const url = url_arg orelse {
        try stdoutWrite(io, "awr: missing URL\n");
        std.process.exit(1);
    };

    // AWR_DAEMON=1 routes the default fetch through the daemon's
    // JSON-RPC `fetch` method instead of running the page pipeline
    // in-process. Same envelope shape on stdout — agents and pipes
    // can flip the env var without changing call sites. Connection-
    // refused exits with a friendly hint so users discover `awrd`.
    //
    // Slice 4 minimal: only the default fetch path honors the var.
    // tools / call / extract / submit will pick it up in subsequent
    // slices once the daemon implements those methods.
    if (daemonModeEnabled()) {
        try runViaDaemon(alloc, io, args[0], url, format_md);
        return;
    }

    const timing_on = std.c.getenv("AWR_TIMING") != null;

    // Telemetry sink — populated through the fetch pipeline whenever
    // AWR_TELEMETRY is set, ignored otherwise. The sink lives across
    // every phase; emission happens in `defer` so even early exits via
    // unhandled errors still get a record. Attaching to Page via
    // `metrics_sink` is what plumbs the sub-phase timings.
    var metrics = telemetry.SessionMetrics.init();
    metrics.url = url;
    defer telemetry.emit(&metrics, alloc, io);

    const t_startup_done = if (timing_on or telemetry.resolveDest(alloc) catch .none != .none) nowMs() else 0;
    var p = try page_mod.Page.init(alloc, io);
    defer p.deinit();
    p.metrics_sink = &metrics;
    p.disable_scripts = disable_scripts;
    if (fetch_extra_headers.items.len > 0) {
        p.client.options.extra_request_headers = fetch_extra_headers.items;
    }
    if (t_startup_done != 0) {
        const elapsed = nowMs() - t_startup_done;
        if (timing_on) std.debug.print("[timing] page_init={d}ms\n", .{elapsed});
        metrics.page_init_ms = elapsed;
    }

    const t_process_start = nowMs();
    var result = loadPage(&p, alloc, io, url) catch |err| {
        fatalLoadErrorWithMetrics(&metrics, alloc, io, "fetching", url, err);
    };
    defer result.deinit();
    metrics.process_html_ms = nowMs() - t_process_start - metrics.navigate_fetch_ms;
    if (metrics.process_html_ms < 0) metrics.process_html_ms = 0;

    const t_render_start = if (timing_on or p.metrics_sink != null) nowMs() else 0;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.append(alloc, '{');
    try buf.appendSlice(alloc, "\"url\":");
    try writeJsonStr(&buf, alloc, result.url);
    const status_str = try std.fmt.allocPrint(alloc, ",\"status\":{d}", .{result.status});
    defer alloc.free(status_str);
    try buf.appendSlice(alloc, status_str);
    try buf.appendSlice(alloc, ",\"title\":");
    if (result.title) |t| try writeJsonStr(&buf, alloc, t) else try buf.appendSlice(alloc, "null");
    if (format_md) {
        // Swap the `body_text` field for the Markdown extraction. Caller
        // can still tell the format from the field name.
        const md = try p.extractMarkdown(alloc);
        defer alloc.free(md);
        try buf.appendSlice(alloc, ",\"body_md\":");
        try writeJsonStr(&buf, alloc, md);
    } else {
        try buf.appendSlice(alloc, ",\"body_text\":");
        try writeJsonStr(&buf, alloc, result.body_text);
    }
    try buf.appendSlice(alloc, ",\"window_data\":");
    if (result.window_data) |wd| try buf.appendSlice(alloc, wd) else try buf.appendSlice(alloc, "null");
    try buf.appendSlice(alloc, ",\"tools\":");
    if (result.tools_json) |tj| try buf.appendSlice(alloc, tj) else try buf.appendSlice(alloc, "[]");
    try buf.appendSlice(alloc, "}\n");

    try stdoutWrite(io, buf.items);
    if (t_render_start != 0) {
        const elapsed = nowMs() - t_render_start;
        if (timing_on) std.debug.print("[timing] json_emit={d}ms ({d}B)\n", .{ elapsed, buf.items.len });
        metrics.json_emit_ms = elapsed;
        metrics.envelope_bytes = buf.items.len;
    }
}

/// T-85 / Tier 1 slice T1.9: `awr session import <browser>` reads
/// cookies from Chrome/Firefox SQLite stores and writes a Netscape
/// `cookies.txt` that subsequent AWR runs can pick up via
/// $AWR_COOKIE_JAR. Useful for "log into the site in my real browser,
/// then let AWR drive it as me."
fn runSessionSubcommand(alloc: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    if (args.len < 3 or !std.mem.eql(u8, args[2], "import")) {
        try stdoutWrite(io, "usage: awr session import <chrome|chromium|firefox> [--out PATH] [--profile NAME] [--source PATH]\n");
        std.process.exit(1);
    }
    if (args.len < 4) {
        try stdoutWrite(io, "usage: awr session import <chrome|chromium|firefox> [--out PATH] [--profile NAME] [--source PATH]\n");
        std.process.exit(1);
    }

    const browser_arg = args[3];
    const browser: session_import.Browser =
        if (std.mem.eql(u8, browser_arg, "chrome")) .chrome else if (std.mem.eql(u8, browser_arg, "chromium")) .chromium else if (std.mem.eql(u8, browser_arg, "firefox")) .firefox else {
            try stdoutWrite(io, "session import: unknown browser '");
            try stdoutWrite(io, browser_arg);
            try stdoutWrite(io, "' (want chrome|chromium|firefox)\n");
            std.process.exit(1);
        };

    var out_path: ?[]const u8 = null;
    var profile: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var ai: usize = 4;
    while (ai < args.len) : (ai += 1) {
        if (std.mem.eql(u8, args[ai], "--out") and ai + 1 < args.len) {
            out_path = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--profile") and ai + 1 < args.len) {
            profile = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--source") and ai + 1 < args.len) {
            source = args[ai + 1];
            ai += 1;
        } else {
            std.process.fatal("session import: unknown arg '{s}'", .{args[ai]});
        }
    }

    // Resolve source DB path.
    var source_owned: ?[]u8 = null;
    defer if (source_owned) |s| alloc.free(s);
    const source_path: []const u8 = if (source) |s| s else blk: {
        const p = session_import.defaultPath(alloc, io, browser, profile) catch |err| {
            std.process.fatal("session import: could not resolve default path: {t}", .{err});
        };
        source_owned = p;
        break :blk p;
    };

    // Resolve output path: --out > $AWR_COOKIE_JAR > ./awr-cookies.txt.
    var out_owned: ?[]u8 = null;
    defer if (out_owned) |o| alloc.free(o);
    const out_resolved: []const u8 = if (out_path) |o| o else blk: {
        if (std.c.getenv("AWR_COOKIE_JAR")) |env_z| {
            const env_s = std.mem.span(env_z);
            if (env_s.len > 0) {
                out_owned = try alloc.dupe(u8, env_s);
                break :blk out_owned.?;
            }
        }
        out_owned = try alloc.dupe(u8, "awr-cookies.txt");
        break :blk out_owned.?;
    };

    var result = session_import.importFromDb(alloc, io, browser, source_path) catch |err| {
        std.process.fatal("session import: read failed ({t}). Is sqlite3 installed and is the DB readable?", .{err});
    };
    defer result.deinit(alloc);

    // Translate ImportedCookies → in-memory CookieJar via parseSetCookie
    // so the parsed result hits the same validation path normal traffic
    // does (skips expired, name-empty, etc.). Then serialize to disk.
    var jar = page_mod.CookieJar.init(alloc);
    defer jar.deinit();
    var imported_count: usize = 0;
    for (result.cookies) |c| {
        // Build a synthetic Set-Cookie header. Format:
        //   <name>=<value>; Path=<path>; Domain=<host>; Secure?; HttpOnly?; Expires=<rfc1123>
        var hdr: std.ArrayList(u8) = .empty;
        defer hdr.deinit(alloc);
        try hdr.appendSlice(alloc, c.name);
        try hdr.append(alloc, '=');
        try hdr.appendSlice(alloc, c.value);
        try hdr.appendSlice(alloc, "; Path=");
        try hdr.appendSlice(alloc, c.path);
        try hdr.appendSlice(alloc, "; Domain=");
        try hdr.appendSlice(alloc, c.host);
        if (c.secure) try hdr.appendSlice(alloc, "; Secure");
        if (c.http_only) try hdr.appendSlice(alloc, "; HttpOnly");
        if (c.expires) |exp| {
            // Use Max-Age (seconds from now) for portability — the jar
            // parses both Expires and Max-Age, and Max-Age is the
            // simpler round-trip target.
            // Inline wall-clock seconds (avoids a duplicate util/time import
            // that would collide with page.zig's own `@import` of the same file).
            var ts2: std.posix.timespec = undefined;
            _ = std.posix.system.clock_gettime(.REALTIME, &ts2);
            const now: i64 = @intCast(ts2.sec);
            const remaining = exp - now;
            if (remaining > 0) {
                var ma_buf: [40]u8 = undefined;
                const ma = try std.fmt.bufPrint(&ma_buf, "; Max-Age={d}", .{remaining});
                try hdr.appendSlice(alloc, ma);
            }
        }
        // request_domain doesn't matter when Domain= is explicit; pass
        // the host as a sane default.
        jar.parseSetCookie(hdr.items, c.host) catch continue;
        imported_count += 1;
    }

    // Write Netscape format.
    var out_file = std.Io.Dir.cwd().createFile(io, out_resolved, .{}) catch |err| {
        std.process.fatal("session import: could not open --out '{s}' for write: {t}", .{ out_resolved, err });
    };
    defer out_file.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = out_file.writer(io, &wbuf);
    try jar.serialize(&fw.interface);
    try fw.interface.flush();

    // Summary line — agent-parseable but human-readable.
    var msg: [256]u8 = undefined;
    const summary = try std.fmt.bufPrint(&msg, "imported {d} cookies → {s} (skipped {d} encrypted)\n", .{ imported_count, out_resolved, result.skipped_encrypted });
    try stdoutWrite(io, summary);
}

/// T-89 / Tier 2 slice T2.1: `awr bookmark <add|list|rm> ...`.
fn runBookmarkSubcommand(alloc: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    if (args.len < 3) {
        try stdoutWrite(io, "usage: awr bookmark <add|list|rm> [args]\n");
        std.process.exit(1);
    }
    const verb = args[2];

    const path = (try bookmarks_mod.defaultPath(alloc, io)) orelse {
        try stdoutWrite(io, "bookmark: could not resolve bookmark store path (set $AWR_BOOKMARKS, $XDG_DATA_HOME, or $HOME)\n");
        std.process.exit(1);
    };
    defer alloc.free(path);

    var store = bookmarks_mod.Store.load(alloc, io, path) catch |err| {
        std.process.fatal("bookmark: load failed: {t}", .{err});
    };
    defer store.deinit();

    if (std.mem.eql(u8, verb, "add")) {
        if (args.len < 4) {
            try stdoutWrite(io, "usage: awr bookmark add <url> [--title=TITLE]\n");
            std.process.exit(1);
        }
        var url: ?[]const u8 = null;
        var title: []const u8 = "";
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.startsWith(u8, args[i], "--title=")) {
                title = args[i]["--title=".len..];
            } else if (std.mem.eql(u8, args[i], "--title") and i + 1 < args.len) {
                title = args[i + 1];
                i += 1;
            } else if (url == null and !std.mem.startsWith(u8, args[i], "--")) {
                url = args[i];
            } else {
                std.process.fatal("bookmark add: unknown arg '{s}'", .{args[i]});
            }
        }
        if (url == null) {
            try stdoutWrite(io, "bookmark add: URL is required\n");
            std.process.exit(1);
        }
        const id = store.add(title, url.?) catch |err| {
            std.process.fatal("bookmark add: {t}", .{err});
        };
        try store.save(io, path);
        var out_buf: [256]u8 = undefined;
        const out_msg = try std.fmt.bufPrint(&out_buf, "added bookmark #{d} → {s}\n", .{ id, path });
        try stdoutWrite(io, out_msg);
        return;
    }

    if (std.mem.eql(u8, verb, "list")) {
        if (store.bookmarks.items.len == 0) {
            try stdoutWrite(io, "(no bookmarks)\n");
            return;
        }
        var line_buf: [4096]u8 = undefined;
        for (store.bookmarks.items) |b| {
            const line = try std.fmt.bufPrint(&line_buf, "{d}\t{d}\t{s}\t{s}\n", .{ b.id, b.created_ts, b.title, b.url });
            try stdoutWrite(io, line);
        }
        return;
    }

    if (std.mem.eql(u8, verb, "rm")) {
        if (args.len < 4) {
            try stdoutWrite(io, "usage: awr bookmark rm <id>\n");
            std.process.exit(1);
        }
        const id = std.fmt.parseInt(u64, args[3], 10) catch {
            std.process.fatal("bookmark rm: id must be a number, got '{s}'", .{args[3]});
        };
        if (!store.remove(id)) {
            var nf: [128]u8 = undefined;
            const nf_msg = try std.fmt.bufPrint(&nf, "bookmark rm: no bookmark with id {d}\n", .{id});
            try stdoutWrite(io, nf_msg);
            std.process.exit(1);
        }
        try store.save(io, path);
        var out_buf: [128]u8 = undefined;
        const out_msg = try std.fmt.bufPrint(&out_buf, "removed bookmark #{d}\n", .{id});
        try stdoutWrite(io, out_msg);
        return;
    }

    try stdoutWrite(io, "bookmark: unknown verb '");
    try stdoutWrite(io, verb);
    try stdoutWrite(io, "' (want add|list|rm)\n");
    std.process.exit(1);
}

test "isFailedCallEnvelope detects {ok:false}" {
    try std.testing.expect(isFailedCallEnvelope("{\"ok\":false,\"error\":\"ToolNotFound\"}"));
    try std.testing.expect(isFailedCallEnvelope("{\"ok\": false, \"error\": \"ToolNotFound\"}"));
    try std.testing.expect(!isFailedCallEnvelope("{\"ok\":true,\"value\":{}}"));
}

test "resolveCookieScope returns 12 hex chars or default" {
    // We can't safely setenv inside a test (libc setenv leaks across
    // tests on some platforms). Resolution depends on env that the
    // test runner provides — at minimum we expect either a valid
    // 12-hex scope (sha1($PWD)[:12]) or the literal "default" if
    // PWD wasn't set. Both shapes are valid — we just check the
    // returned slice is allocator-owned and non-empty.
    const allocator = std.testing.allocator;
    const scope = try resolveCookieScope(allocator);
    defer allocator.free(scope);
    try std.testing.expect(scope.len > 0);
    // If sha1[:12] path was taken, scope is exactly 12 lowercase
    // hex chars. Otherwise it's "default" or whatever
    // AWR_COOKIE_SCOPE happens to be in the env. Validate the hex
    // shape only when length matches.
    if (scope.len == 12) {
        for (scope) |c| try std.testing.expect(
            (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'),
        );
    }
}

test "describeLoadError returns stable messages for common failures" {
    try std.testing.expectEqualStrings("invalid URL", describeLoadError(error.InvalidUrl));
    try std.testing.expectEqualStrings("DNS resolution failed", describeLoadError(error.DnsResolutionFailed));
    try std.testing.expectEqualStrings("file not found", describeLoadError(error.FileNotFound));
}
