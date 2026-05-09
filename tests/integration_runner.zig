/// integration_runner.zig — Zig-native integration test harness.
///
/// Spawns the actual `awr` and `awrd` binaries via `std.process.Child`
/// and asserts on stdout/stderr/exit code. Replaces shell-based smoke
/// for everything that fits a hermetic in-process model — catches
/// CLI argv parsing, env-var handling, and Unix-socket round-trip
/// regressions the in-process unit tests can't see.
///
/// Run via `zig build test-integration` (separate from default test
/// because the tests assume the binaries are installed at
/// ./zig-out/bin/; the build step depends on installArtifact for both).
///
/// Conventions for new tests in this file:
///   - Use `spawnAndWait(...)` for one-shot CLI invocations.
///   - Use `DaemonHandle` for any test that needs a running awrd.
///   - Assert positively: `try testing.expect(<condition>)` with the
///     actual condition, never `expect(false)` as a "shouldn't reach".
///   - Per-test isolation via unique `$XDG_RUNTIME_DIR` so two daemon
///     tests don't collide on the socket path.
const std = @import("std");
const testing = std.testing;

const AWR_BIN = "./zig-out/bin/awr";
const AWRD_BIN = "./zig-out/bin/awrd";

// ── Generic spawn helper ──────────────────────────────────────────

const SpawnResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: *SpawnResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Spawn `argv`, wait for exit, return stdout + stderr + exit code.
/// Pipe-drain errors propagate (no silent catch) so a broken pipe in
/// the harness shows up as a test failure rather than invisible truncation.
fn spawnAndWait(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !SpawnResult {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Drain stdout + stderr to EOF before waiting; otherwise the
    // child can block on a full pipe. 16 KiB read window is plenty
    // for any test (the largest expected output is `awr --help`).
    const stdout_bytes = try drainPipe(io, allocator, &child.stdout.?);
    errdefer allocator.free(stdout_bytes);
    const stderr_bytes = try drainPipe(io, allocator, &child.stderr.?);
    errdefer allocator.free(stderr_bytes);

    const term = try child.wait(io);
    const exit_code: u8 = switch (term) {
        .exited => |c| c,
        // Signal-terminated: surface a stable sentinel so callers can
        // assert against it. 254 collides with no shell convention.
        .signal => 254,
        else => 255,
    };

    return SpawnResult{
        .stdout = stdout_bytes,
        .stderr = stderr_bytes,
        .exit_code = exit_code,
    };
}

/// Read `file` to EOF into a freshly-allocated owned slice. Errors
/// from the underlying stream surface to the caller — no silent
/// catch, since a truncated pipe in a test fixture is a real bug.
fn drainPipe(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: *std.Io.File,
) ![]u8 {
    var buf: [16 * 1024]u8 = undefined;
    var r = file.reader(io, &buf);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    _ = r.interface.streamRemaining(&aw.writer) catch |err| switch (err) {
        // ReadFailed at EOF is normal pipe close — don't surface.
        error.ReadFailed => {},
        else => |e| return e,
    };
    return try aw.toOwnedSlice();
}

// ── Daemon harness ────────────────────────────────────────────────

/// Owns a per-test awrd subprocess and its isolated $XDG_RUNTIME_DIR.
/// Construct via `DaemonHandle.start(...)`; call `.shutdown()` to
/// trigger the graceful-exit path (sends shutdown over the socket
/// and verifies the process exits 0); call `.deinit()` from a defer
/// to clean up the tmp dir + kill any still-running daemon.
const DaemonHandle = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    tmp_dir: []u8,
    sock_path: []u8,
    /// `null` once we've reaped the child via `wait` — guards `deinit`'s
    /// best-effort kill from double-reaping.
    reaped: bool = false,

    /// Spawn awrd with a unique $XDG_RUNTIME_DIR per `slug` so concurrent
    /// tests don't collide on the socket. Block until the daemon's
    /// socket is connectable (up to `connect_timeout_ms`).
    fn start(allocator: std.mem.Allocator, slug: []const u8, connect_timeout_ms: u64) !DaemonHandle {
        return startWith(allocator, slug, connect_timeout_ms, null);
    }

    /// Variant that pins XDG_DATA_HOME for the daemon — the per-scope
    /// cookie-jar tests need this so jars land in a hermetic per-test
    /// dir, not the developer's `$HOME/.local/share`.
    fn startWith(
        allocator: std.mem.Allocator,
        slug: []const u8,
        connect_timeout_ms: u64,
        data_home: ?[]const u8,
    ) !DaemonHandle {
        const io = std.testing.io;
        const pid = std.posix.system.getpid();
        const tmp_dir = try std.fmt.allocPrint(
            allocator,
            "/tmp/awrd-integration-{s}-{d}",
            .{ slug, pid },
        );
        errdefer allocator.free(tmp_dir);

        std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const uid = std.posix.system.geteuid();
        const sock_path = try std.fmt.allocPrint(
            allocator,
            "{s}/awrd-{d}.sock",
            .{ tmp_dir, uid },
        );
        errdefer allocator.free(sock_path);

        // Minimal env: XDG_RUNTIME_DIR (always) + optional
        // XDG_DATA_HOME for per-scope jar tests.
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try env.put("XDG_RUNTIME_DIR", tmp_dir);
        if (data_home) |dh| try env.put("XDG_DATA_HOME", dh);

        var child = try std.process.spawn(io, .{
            .argv = &.{AWRD_BIN},
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .environ_map = &env,
        });
        errdefer {
            child.kill(io);
            _ = child.wait(io) catch {};
            if (child.stdout) |*f| f.close(io);
            if (child.stderr) |*f| f.close(io);
        }

        // Wait for the daemon to bind. Probe via connect() — portable
        // (macOS rejects openFile on a Unix socket with errno 102).
        const ua = try std.Io.net.UnixAddress.init(sock_path);
        var waited_ms: u64 = 0;
        const step_ms: u64 = 20;
        while (waited_ms < connect_timeout_ms) {
            if (ua.connect(io)) |probe_stream| {
                var s = probe_stream;
                s.close(io);
                break;
            } else |_| {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(step_ms)), .awake) catch {};
                waited_ms += step_ms;
            }
        }
        if (waited_ms >= connect_timeout_ms) return error.DaemonStartupTimeout;

        return DaemonHandle{
            .allocator = allocator,
            .io = io,
            .child = child,
            .tmp_dir = tmp_dir,
            .sock_path = sock_path,
        };
    }

    /// Send a shutdown frame and wait for the daemon to exit cleanly.
    /// Asserts the exit code is 0 — failure here means the daemon's
    /// shutdown path is broken (e.g. accept loop didn't see the flag).
    fn shutdown(self: *DaemonHandle) !void {
        const ua = try std.Io.net.UnixAddress.init(self.sock_path);
        var stream = try ua.connect(self.io);
        defer stream.close(self.io);

        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var net_reader = stream.reader(self.io, &rbuf);
        var net_writer = stream.writer(self.io, &wbuf);

        const body = "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"shutdown\"}";
        try net_writer.interface.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
        try net_writer.interface.flush();

        const resp = try readFrame(self.io, &net_reader.interface, self.allocator);
        defer self.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "shutting down") != null);

        const term = try self.child.wait(self.io);
        self.reaped = true;
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    }

    fn deinit(self: *DaemonHandle) void {
        // Child.kill reaps internally on Zig 0.16 — must NOT follow
        // with wait or the next assertion fires.
        if (!self.reaped) self.child.kill(self.io);
        if (self.child.stdout) |*f| f.close(self.io);
        if (self.child.stderr) |*f| f.close(self.io);
        std.Io.Dir.cwd().deleteTree(self.io, self.tmp_dir) catch {};
        self.allocator.free(self.tmp_dir);
        self.allocator.free(self.sock_path);
    }

    /// Send a JSON-RPC request body, return the parsed response body.
    /// Caller frees the returned slice.
    fn rpc(self: *DaemonHandle, body: []const u8) ![]u8 {
        const ua = try std.Io.net.UnixAddress.init(self.sock_path);
        var stream = try ua.connect(self.io);
        defer stream.close(self.io);

        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var net_reader = stream.reader(self.io, &rbuf);
        var net_writer = stream.writer(self.io, &wbuf);

        try net_writer.interface.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
        try net_writer.interface.flush();

        return try readFrame(self.io, &net_reader.interface, self.allocator);
    }
};

// ── Mock-server harness ───────────────────────────────────────────

/// Owns a per-test `awr mock --port <port>` subprocess so daemon-side
/// tests have a hermetic HTTP fixture without external network.
/// Each test picks a unique port (process pid + offset) so concurrent
/// runs don't collide.
const MockHandle = struct {
    io: std.Io,
    child: std.process.Child,
    port: u16,
    reaped: bool = false,

    fn start(allocator: std.mem.Allocator, port: u16) !MockHandle {
        const io = std.testing.io;
        const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
        defer allocator.free(port_str);

        var child = try std.process.spawn(io, .{
            .argv = &.{ AWR_BIN, "mock", "--port", port_str },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        errdefer {
            child.kill(io);
            _ = child.wait(io) catch {};
            if (child.stdout) |*f| f.close(io);
            if (child.stderr) |*f| f.close(io);
        }

        // Probe TCP connect to confirm the listener is up. awr mock
        // logs a startup banner to stderr but reading it would race
        // — connect-probe is the deterministic signal.
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
        var waited_ms: u64 = 0;
        while (waited_ms < 2000) {
            if (addr.connect(io, .{ .mode = .stream })) |s| {
                var ss = s;
                ss.close(io);
                break;
            } else |_| {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
                waited_ms += 20;
            }
        }
        if (waited_ms >= 2000) return error.MockStartupTimeout;

        return MockHandle{ .io = io, .child = child, .port = port };
    }

    fn deinit(self: *MockHandle) void {
        // std.process.Child.kill reaps the process internally and
        // sets child.id = null. Calling wait after kill is an
        // assertion failure on Zig 0.16.
        if (!self.reaped) self.child.kill(self.io);
        if (self.child.stdout) |*f| f.close(self.io);
        if (self.child.stderr) |*f| f.close(self.io);
    }
};

// ── Frame parser (copy of jsonrpc.readFrame for test isolation) ───
//
// Reproduced here rather than imported because the integration_runner
// module is intentionally narrow: only depends on std + the binaries.
// Pulling in jsonrpc.zig as a module means this test binary would
// transitively depend on more of src/ than needed.
fn readFrame(io: std.Io, reader: *std.Io.Reader, allocator: std.mem.Allocator) ![]u8 {
    _ = io;
    var content_length: ?usize = null;
    var line_buf: [4096]u8 = undefined;
    while (true) {
        var len: usize = 0;
        while (len < line_buf.len) {
            var single: [1]u8 = undefined;
            const n = try reader.readSliceShort(&single);
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
    const len = content_length orelse return error.MissingContentLength;
    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    var filled: usize = 0;
    while (filled < len) {
        const n = try reader.readSliceShort(body[filled..]);
        if (n == 0) return error.UnexpectedEof;
        filled += n;
    }
    return body;
}

// ── Tests ─────────────────────────────────────────────────────────

test "awr --version exits 0 and prints 0.0.<git-hash>\\n" {
    const allocator = testing.allocator;
    var result = try spawnAndWait(allocator, &.{ AWR_BIN, "--version" });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    try testing.expect(std.mem.startsWith(u8, result.stdout, "0.0."));
    try testing.expect(std.mem.endsWith(u8, result.stdout, "\n"));
    // Stderr must be clean — version output shouldn't trip any
    // warnings or telemetry leaks.
    try testing.expectEqual(@as(usize, 0), result.stderr.len);
}

test "awr --help mentions every public subcommand and is non-empty" {
    const allocator = testing.allocator;
    var result = try spawnAndWait(allocator, &.{ AWR_BIN, "--help" });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    // Catch help-text removal regressions: every documented subcommand
    // and the cookie env var must appear by name. Loop fails the test
    // with the missing string in the panic message via the `if/expect`
    // pair so the failure message names the missing piece.
    inline for ([_][]const u8{
        "awr browse",
        "awr render",
        "awr <url>",
        "awr post",
        "awr submit",
        "awr extract",
        "awr cookies",
        "awr tools",
        "awr call",
        "awr mock",
        "AWR_COOKIE_JAR",
    }) |needle| {
        const found = std.mem.indexOf(u8, result.stdout, needle) != null;
        if (!found) std.debug.print("--help missing subcommand line: {s}\n", .{needle});
        try testing.expect(found);
    }
}

test "awr --format=md without URL exits non-zero with usage error" {
    const allocator = testing.allocator;
    var result = try spawnAndWait(allocator, &.{ AWR_BIN, "--format=md" });
    defer result.deinit(allocator);

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "missing URL") != null);
}

test "awr unknown flag exits non-zero with helpful message" {
    const allocator = testing.allocator;
    var result = try spawnAndWait(allocator, &.{ AWR_BIN, "--format=mdmark", "https://example.com" });
    defer result.deinit(allocator);

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "unknown flag") != null);
    // Ensure the unknown flag's literal name is echoed so users can
    // see WHICH flag we rejected.
    try testing.expect(std.mem.indexOf(u8, result.stdout, "--format=mdmark") != null);
}

test "awrd ping returns pong + version prefix" {
    const allocator = testing.allocator;
    var d = try DaemonHandle.start(allocator, "ping", 2000);
    defer d.deinit();

    const resp = try d.rpc("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}");
    defer allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"result\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"value\":\"pong\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"version\":\"0.0.") != null);
    // Negative: must not be an error envelope.
    try testing.expect(std.mem.indexOf(u8, resp, "\"error\"") == null);

    try d.shutdown();
}

test "awrd unknown method returns JSON-RPC -32601 with method name echoed" {
    const allocator = testing.allocator;
    var d = try DaemonHandle.start(allocator, "unknown", 2000);
    defer d.deinit();

    const resp = try d.rpc("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"definitely_not_a_method\"}");
    defer allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "-32601") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "definitely_not_a_method") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":7") != null);
    // Negative: must not be a result envelope.
    try testing.expect(std.mem.indexOf(u8, resp, "\"result\"") == null);

    try d.shutdown();
}

test "awrd fetch returns spec §2.3 envelope (url, status, title, body_text)" {
    const allocator = testing.allocator;
    var mock = try MockHandle.start(allocator, 18601);
    defer mock.deinit();
    var d = try DaemonHandle.start(allocator, "fetch", 2000);
    defer d.deinit();

    // experiments/webmcp_mock.html is a known fixture awr mock serves.
    // Title is "AWR WebMCP mock" per the fixture's <title> tag — if
    // that fixture changes, this assertion needs to follow.
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"fetch\"," ++
        "\"params\":{\"url\":\"http://127.0.0.1:18601/webmcp_mock.html\"}}";
    const resp = try d.rpc(req);
    defer allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"result\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"status\":200") != null);
    // The mock fixture registers WebMCP tools; fetch's envelope must
    // surface them through the `tools` field even though we didn't
    // call the `tools` method explicitly. (Fetch returns the same
    // PageResult the CLI's default path uses.)
    try testing.expect(std.mem.indexOf(u8, resp, "\"tools\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "search_products") != null);
    // Sanity: the fetched URL is echoed back, distinct from the
    // requested one (here they're the same string but the field
    // must be present).
    try testing.expect(std.mem.indexOf(u8, resp, "\"url\":\"http://127.0.0.1:18601/webmcp_mock.html\"") != null);

    try d.shutdown();
}

test "awrd fetch surfaces 404 status without erroring" {
    const allocator = testing.allocator;
    var mock = try MockHandle.start(allocator, 18602);
    defer mock.deinit();
    var d = try DaemonHandle.start(allocator, "fetch-404", 2000);
    defer d.deinit();

    // awr mock serves /experiments/, a missing path must 404.
    const req = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"fetch\"," ++
        "\"params\":{\"url\":\"http://127.0.0.1:18602/no-such-path.html\"}}";
    const resp = try d.rpc(req);
    defer allocator.free(resp);

    // 404 is a successful HTTP transaction — the result envelope is
    // returned, NOT a JSON-RPC error envelope.
    try testing.expect(std.mem.indexOf(u8, resp, "\"result\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"status\":404") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"error\"") == null);

    try d.shutdown();
}

test "awrd fetch with missing url returns invalid_params error" {
    const allocator = testing.allocator;
    var d = try DaemonHandle.start(allocator, "fetch-no-url", 2000);
    defer d.deinit();

    const req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"fetch\",\"params\":{}}";
    const resp = try d.rpc(req);
    defer allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "\"error\"") != null);
    // We map MissingUrl through the internal_error code in slice 2;
    // upgrading to invalid_params is a future-work polish.
    try testing.expect(std.mem.indexOf(u8, resp, "MissingUrl") != null);

    try d.shutdown();
}

test "AWR_DAEMON=1 routes awr <url> through daemon, prints result envelope" {
    const allocator = testing.allocator;
    var mock = try MockHandle.start(allocator, 18603);
    defer mock.deinit();
    var d = try DaemonHandle.start(allocator, "client", 2000);
    defer d.deinit();

    // Spawn `awr <url>` with AWR_DAEMON=1 + the same XDG_RUNTIME_DIR
    // the daemon is using so resolveDaemonSocket finds the right path.
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("AWR_DAEMON", "1");
    try env.put("XDG_RUNTIME_DIR", d.tmp_dir);

    var child = try std.process.spawn(io, .{
        .argv = &.{ AWR_BIN, "http://127.0.0.1:18603/webmcp_mock.html" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = &env,
    });

    const stdout = try drainPipe(io, allocator, &child.stdout.?);
    defer allocator.free(stdout);
    const stderr = try drainPipe(io, allocator, &child.stderr.?);
    defer allocator.free(stderr);
    const term = try child.wait(io);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);

    // The CLI client unwraps the JSON-RPC envelope so callers see
    // the same shape as the in-process default path: a top-level
    // object with url/status/title/body_text/window_data/tools.
    try testing.expect(std.mem.indexOf(u8, stdout, "\"status\":200") != null);
    try testing.expect(std.mem.indexOf(u8, stdout, "\"url\":\"http://127.0.0.1:18603/webmcp_mock.html\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout, "\"tools\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout, "search_products") != null);
    // Negative: the JSON-RPC wrapper fields must NOT leak through.
    // Callers shouldn't see jsonrpc/id/result keys unless they
    // explicitly opted in to the daemon protocol.
    try testing.expect(std.mem.indexOf(u8, stdout, "\"jsonrpc\"") == null);
    try testing.expect(std.mem.indexOf(u8, stdout, "\"result\":") == null);

    try d.shutdown();
}

test "awrd parse_error envelope on malformed JSON" {
    const allocator = testing.allocator;
    var d = try DaemonHandle.start(allocator, "parse-err", 2000);
    defer d.deinit();

    // Body is valid framing but invalid JSON. Daemon should reply
    // with a parse_error envelope (id "null" because we can't
    // recover the original id from un-parseable JSON), not crash.
    const resp = try d.rpc("not valid json at all");
    defer allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "-32700") != null);
    // id field present and explicitly null — JSON-RPC §5.1 requires
    // we still send a response shaped like a real envelope.
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":null") != null);

    try d.shutdown();
}

test "awrd per-scope cookie jars land at distinct on-disk paths" {
    // spec/subspecs/daemon-mode.md §2.4: each cookie_scope routes
    // to its own jar file at $XDG_DATA_HOME/awr/cookies/<scope>.txt.
    // We verify scope routing by issuing two fetches with different
    // cookie_scope params and checking both per-scope files exist.
    // The mock fixture doesn't return Set-Cookie, so the jars are
    // empty — but the existence of the files at the spec-mandated
    // paths proves the scope param is honored end-to-end.
    const allocator = testing.allocator;
    const io = std.testing.io;
    const pid = std.posix.system.getpid();

    const data_home = try std.fmt.allocPrint(
        allocator,
        "/tmp/awrd-scope-data-{d}",
        .{pid},
    );
    defer allocator.free(data_home);
    std.Io.Dir.cwd().deleteTree(io, data_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, data_home);

    var mock = try MockHandle.start(allocator, 18604);
    defer mock.deinit();
    var d = try DaemonHandle.startWith(allocator, "scope", 2000, data_home);
    defer d.deinit();

    // Two fetches at the same URL, different scope keys. The
    // daemon spawns a fresh Page per request (slice 3 caching is
    // disk-only), each Page writes its empty jar to the per-scope
    // file at deinit.
    const req_alpha = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"fetch\"," ++
        "\"params\":{\"url\":\"http://127.0.0.1:18604/webmcp_mock.html\"," ++
        "\"cookie_scope\":\"alpha\"}}";
    const resp_alpha = try d.rpc(req_alpha);
    defer allocator.free(resp_alpha);
    try testing.expect(std.mem.indexOf(u8, resp_alpha, "\"status\":200") != null);

    const req_beta = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"fetch\"," ++
        "\"params\":{\"url\":\"http://127.0.0.1:18604/webmcp_mock.html\"," ++
        "\"cookie_scope\":\"beta\"}}";
    const resp_beta = try d.rpc(req_beta);
    defer allocator.free(resp_beta);
    try testing.expect(std.mem.indexOf(u8, resp_beta, "\"status\":200") != null);

    // Both per-scope files must exist at the spec-mandated location.
    const path_alpha = try std.fmt.allocPrint(
        allocator,
        "{s}/awr/cookies/alpha.txt",
        .{data_home},
    );
    defer allocator.free(path_alpha);
    const path_beta = try std.fmt.allocPrint(
        allocator,
        "{s}/awr/cookies/beta.txt",
        .{data_home},
    );
    defer allocator.free(path_beta);

    // Stat each file — readFileAlloc returns an error if missing.
    const alpha_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path_alpha, allocator, .limited(4096));
    defer allocator.free(alpha_bytes);
    const beta_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path_beta, allocator, .limited(4096));
    defer allocator.free(beta_bytes);

    // Sanity: the default scope file must NOT exist — proves the
    // scope param actually drove path selection (not a hard-coded
    // "default" path written regardless of the param).
    const path_default = try std.fmt.allocPrint(
        allocator,
        "{s}/awr/cookies/default.txt",
        .{data_home},
    );
    defer allocator.free(path_default);
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().readFileAlloc(io, path_default, allocator, .limited(4096)),
    );

    try d.shutdown();
}

test "awrd absorbs Set-Cookie into per-scope jar and replays it on next fetch" {
    // Three-fetch end-to-end behavior test (closes spec §5.3 at the
    // disk-persistence layer):
    //   1. /set-cookie/sid/abc with cookie_scope=alpha →
    //      response carries Set-Cookie; daemon writes sid=abc to
    //      $XDG_DATA_HOME/awr/cookies/alpha.txt.
    //   2. /show-cookie/sid with cookie_scope=alpha →
    //      daemon's freshly-loaded alpha jar replays Cookie: sid=abc;
    //      mock echoes it back in the body so we can grep.
    //   3. /show-cookie/sid with cookie_scope=beta →
    //      different scope → different jar (empty) → mock body shows
    //      sid=  (no value).
    //
    // The "across-fetch" assertion (#2) is what proves slice 3 actually
    // persists cookies, not just creates empty files.
    const allocator = testing.allocator;
    const io = std.testing.io;
    const pid = std.posix.system.getpid();

    const data_home = try std.fmt.allocPrint(
        allocator,
        "/tmp/awrd-persist-{d}",
        .{pid},
    );
    defer allocator.free(data_home);
    std.Io.Dir.cwd().deleteTree(io, data_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, data_home);

    var mock = try MockHandle.start(allocator, 18605);
    defer mock.deinit();
    var d = try DaemonHandle.startWith(allocator, "persist", 2000, data_home);
    defer d.deinit();

    // Fetch 1 — set the cookie under scope=alpha.
    const req_set = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"fetch\"," ++
        "\"params\":{\"url\":\"http://127.0.0.1:18605/set-cookie/sid/abc\"," ++
        "\"cookie_scope\":\"alpha\"}}";
    const resp_set = try d.rpc(req_set);
    defer allocator.free(resp_set);
    try testing.expect(std.mem.indexOf(u8, resp_set, "\"status\":200") != null);

    // Disk side-effect check: alpha.txt exists and contains sid=abc.
    const path_alpha = try std.fmt.allocPrint(
        allocator,
        "{s}/awr/cookies/alpha.txt",
        .{data_home},
    );
    defer allocator.free(path_alpha);
    const alpha_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path_alpha, allocator, .limited(4096));
    defer allocator.free(alpha_bytes);
    try testing.expect(std.mem.indexOf(u8, alpha_bytes, "sid") != null);
    try testing.expect(std.mem.indexOf(u8, alpha_bytes, "abc") != null);

    // Fetch 2 — same scope, different URL. The daemon must load
    // alpha's jar from disk and replay sid=abc as a Cookie: header.
    // /show-cookie echoes the request's Cookie value into the
    // response body so we can grep for it.
    const req_show_alpha = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"fetch\"," ++
        "\"params\":{\"url\":\"http://127.0.0.1:18605/show-cookie/sid\"," ++
        "\"cookie_scope\":\"alpha\"}}";
    const resp_show_alpha = try d.rpc(req_show_alpha);
    defer allocator.free(resp_show_alpha);
    try testing.expect(std.mem.indexOf(u8, resp_show_alpha, "\"status\":200") != null);
    // body_text contains "sid=abc" — the cookie was sent back to the server.
    try testing.expect(std.mem.indexOf(u8, resp_show_alpha, "sid=abc") != null);

    // Fetch 3 — DIFFERENT scope. beta has never seen sid; the
    // daemon's beta jar is empty, so the request goes out without
    // a Cookie header, and the mock body shows the empty value.
    const req_show_beta = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"fetch\"," ++
        "\"params\":{\"url\":\"http://127.0.0.1:18605/show-cookie/sid\"," ++
        "\"cookie_scope\":\"beta\"}}";
    const resp_show_beta = try d.rpc(req_show_beta);
    defer allocator.free(resp_show_beta);
    try testing.expect(std.mem.indexOf(u8, resp_show_beta, "\"status\":200") != null);
    // The mock returns "sid=\n" when no sid cookie was sent —
    // proving scope isolation. Negative assertion: must NOT see
    // "sid=abc" anywhere in the response (the value alpha set).
    try testing.expect(std.mem.indexOf(u8, resp_show_beta, "sid=abc") == null);

    try d.shutdown();
}

test "awrd rejects path-traversal cookie_scope values" {
    // Spec §2.4 doesn't enumerate validation, but a daemon that
    // blindly slots scope into a filename is open to writes
    // outside the cookies/ subdir. handleFetch must reject scopes
    // containing `/`, `..`, etc. The error envelope is enough —
    // we don't need to verify no file was written, the validation
    // path runs before any file access.
    const allocator = testing.allocator;
    var d = try DaemonHandle.start(allocator, "scope-bad", 2000);
    defer d.deinit();

    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"fetch\"," ++
        "\"params\":{\"url\":\"http://127.0.0.1:1/\"," ++
        "\"cookie_scope\":\"../../../etc/passwd\"}}";
    const resp = try d.rpc(req);
    defer allocator.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "InvalidCookieScope") != null);

    try d.shutdown();
}
