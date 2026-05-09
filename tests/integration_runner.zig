/// integration_runner.zig — Zig-native integration test harness.
///
/// Spawns the actual `awr` and `awrd` binaries (not just calls into
/// the lib like test_e2e.zig) and asserts on stdout/stderr/exit code.
/// Replaces the .sh smoke suite for everything that fits a hermetic
/// in-process model. Network-dependent assertions stay in
/// scripts/regression_smoke.sh, which is harder to convert without
/// a stub harness.
///
/// Why this is its own runner (vs. extending test_e2e or wpt_runner):
///   - test_e2e is in-process: calls Client/Page directly, doesn't
///     exercise CLI argv parsing, env-var handling, or the daemon
///     binary at all.
///   - wpt_runner spawns an in-process EchoServer for fixtures but
///     also runs everything through the in-process Page pipeline.
///   - This runner uses `std.process.Child` to launch the actual
///     binaries — catching CLI bugs, env-handling bugs, and any
///     boundary-crossing issue the in-process tests miss.
///
/// Run via `zig build test-integration`. Not part of the default
/// `zig build test` because it requires the binaries to be built
/// first (chicken/egg in the test step).
const std = @import("std");
const testing = std.testing;

const AWR_BIN = "./zig-out/bin/awr";
const AWRD_BIN = "./zig-out/bin/awrd";

// ── Helpers ──────────────────────────────────────────────────────

const SpawnResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: *SpawnResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Spawn `argv` (path + args), wait for exit, return captured stdout +
/// stderr + exit code. Caller frees stdout and stderr via SpawnResult.deinit.
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

    // Read stdout + stderr to EOF before waiting, otherwise the child
    // can block on a full pipe. Bounded reads guard against runaway
    // output (16 MiB is more than any test should ever produce).
    const stdout_bytes = blk: {
        var f = child.stdout.?;
        var buf: [16 * 1024]u8 = undefined;
        var r = f.reader(io, &buf);
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        _ = r.interface.streamRemaining(&aw.writer) catch {};
        break :blk try aw.toOwnedSlice();
    };
    errdefer allocator.free(stdout_bytes);

    const stderr_bytes = blk: {
        var f = child.stderr.?;
        var buf: [16 * 1024]u8 = undefined;
        var r = f.reader(io, &buf);
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        _ = r.interface.streamRemaining(&aw.writer) catch {};
        break :blk try aw.toOwnedSlice();
    };
    errdefer allocator.free(stderr_bytes);

    const term = try child.wait(io);
    const exit_code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };

    return SpawnResult{
        .stdout = stdout_bytes,
        .stderr = stderr_bytes,
        .exit_code = exit_code,
    };
}

// ── Tests ────────────────────────────────────────────────────────

test "awr --version exits 0 with version string" {
    const allocator = testing.allocator;
    var result = try spawnAndWait(allocator, &.{ AWR_BIN, "--version" });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    // Version is `0.0.<git-hash>\n`. Just check the prefix.
    try testing.expect(std.mem.startsWith(u8, result.stdout, "0.0."));
}

test "awr --help mentions every public subcommand" {
    const allocator = testing.allocator;
    var result = try spawnAndWait(allocator, &.{ AWR_BIN, "--help" });
    defer result.deinit(allocator);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    // Each curated subcommand must appear in the help text. Catches
    // accidental-removal bugs and missing-help-text PRs.
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
        if (std.mem.indexOf(u8, result.stdout, needle) == null) {
            std.debug.print("help missing: '{s}'\n", .{needle});
            try testing.expect(false);
        }
    }
}

test "awr <missing-url> exits non-zero with usage message" {
    const allocator = testing.allocator;
    var result = try spawnAndWait(allocator, &.{ AWR_BIN, "--format=md" });
    defer result.deinit(allocator);

    try testing.expect(result.exit_code != 0);
    // Stdout (not stderr) per current main.zig; checked literally so
    // we catch silent removals of the friendly message.
    try testing.expect(std.mem.indexOf(u8, result.stdout, "missing URL") != null);
}

test "awr --format=mdmark unknown flag exits with usage error" {
    const allocator = testing.allocator;
    var result = try spawnAndWait(allocator, &.{ AWR_BIN, "--format=mdmark", "https://example.com" });
    defer result.deinit(allocator);

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "unknown flag") != null);
}

test "awrd ping/shutdown round-trip over Unix socket" {
    const allocator = testing.allocator;

    // Per-test socket path so concurrent runs don't collide. The
    // daemon resolves $XDG_RUNTIME_DIR + uid; pinning XDG_RUNTIME_DIR
    // to a unique tmp dir gives us a unique socket without daemon
    // changes. Use pid for uniqueness — std.time.nanoTimestamp was
    // removed from std in Zig 0.16.
    const pid = std.posix.system.getpid();
    const tmp_dir = try std.fmt.allocPrint(
        allocator,
        "/tmp/awrd-integration-{d}",
        .{pid},
    );
    defer allocator.free(tmp_dir);

    const io = std.testing.io;
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Compute the expected socket path the daemon will use:
    // $XDG_RUNTIME_DIR/awrd-$(uid).sock
    const uid = std.posix.system.geteuid();
    const sock_path = try std.fmt.allocPrint(allocator, "{s}/awrd-{d}.sock", .{ tmp_dir, uid });
    defer allocator.free(sock_path);

    // Spawn awrd with our isolated XDG_RUNTIME_DIR.
    // Minimal env: only XDG_RUNTIME_DIR. main_daemon.zig:resolveSocketPath
    // reads only that; we don't need PATH/HOME for awrd's startup.
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("XDG_RUNTIME_DIR", tmp_dir);

    var daemon = try std.process.spawn(io, .{
        .argv = &.{AWRD_BIN},
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = &env,
    });

    // Wait for the daemon to bind. Polling via connect() is more
    // portable than openFile (macOS errno 102 / ENOPROTOOPT for
    // opening a socket as a file): try to connect, close on success.
    const probe_ua = try std.Io.net.UnixAddress.init(sock_path);
    var waited_ms: u64 = 0;
    while (waited_ms < 2000) {
        if (probe_ua.connect(io)) |probe_stream| {
            var s = probe_stream;
            s.close(io);
            break;
        } else |_| {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
            waited_ms += 20;
        }
    }
    if (waited_ms >= 2000) {
        daemon.kill(io);
        return error.DaemonStartupTimeout;
    }

    defer {
        // If the test fails before sending shutdown, kill the daemon
        // so we don't orphan it.
        if (daemon.id != null) {
            daemon.kill(io);
        }
        if (daemon.stdout) |*f| f.close(io);
        if (daemon.stderr) |*f| f.close(io);
        std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    }

    // Connect and send a `ping` frame.
    const ua = try std.Io.net.UnixAddress.init(sock_path);
    var stream = try ua.connect(io);
    defer stream.close(io);

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var net_reader = stream.reader(io, &rbuf);
    var net_writer = stream.writer(io, &wbuf);

    const ping_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
    try net_writer.interface.print("Content-Length: {d}\r\n\r\n{s}", .{ ping_body.len, ping_body });
    try net_writer.interface.flush();

    // Read the framed response. Header up to the blank line, then
    // exactly Content-Length bytes.
    const response_body = try readFrame(io, &net_reader.interface, allocator);
    defer allocator.free(response_body);

    try testing.expect(std.mem.indexOf(u8, response_body, "\"result\"") != null);
    try testing.expect(std.mem.indexOf(u8, response_body, "\"value\":\"pong\"") != null);
    try testing.expect(std.mem.indexOf(u8, response_body, "\"version\":\"0.0.") != null);

    // Send shutdown — daemon should exit cleanly.
    var stream2 = try ua.connect(io);
    defer stream2.close(io);
    var net_reader2 = stream2.reader(io, &rbuf);
    var net_writer2 = stream2.writer(io, &wbuf);
    const shutdown_body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}";
    try net_writer2.interface.print("Content-Length: {d}\r\n\r\n{s}", .{ shutdown_body.len, shutdown_body });
    try net_writer2.interface.flush();

    const shutdown_resp = try readFrame(io, &net_reader2.interface, allocator);
    defer allocator.free(shutdown_resp);
    try testing.expect(std.mem.indexOf(u8, shutdown_resp, "shutting down") != null);

    const term = try daemon.wait(io);
    daemon.id = null; // signal the defer block we've already reaped
    switch (term) {
        .exited => |c| try testing.expectEqual(@as(u8, 0), c),
        else => try testing.expect(false),
    }
}

test "awrd unknown method returns JSON-RPC -32601" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    const pid = std.posix.system.getpid();
    const tmp_dir = try std.fmt.allocPrint(
        allocator,
        "/tmp/awrd-integration-um-{d}",
        .{pid},
    );
    defer allocator.free(tmp_dir);
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const uid = std.posix.system.geteuid();
    const sock_path = try std.fmt.allocPrint(allocator, "{s}/awrd-{d}.sock", .{ tmp_dir, uid });
    defer allocator.free(sock_path);

    // Minimal env: only XDG_RUNTIME_DIR. main_daemon.zig:resolveSocketPath
    // reads only that; we don't need PATH/HOME for awrd's startup.
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("XDG_RUNTIME_DIR", tmp_dir);

    var daemon = try std.process.spawn(io, .{
        .argv = &.{AWRD_BIN},
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = &env,
    });
    defer {
        daemon.kill(io);
        if (daemon.stdout) |*f| f.close(io);
        if (daemon.stderr) |*f| f.close(io);
        std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    }

    // Wait for socket via connect-probe (portable; openFile on a
    // Unix socket fails with macOS errno 102 / ENOPROTOOPT).
    const ua = try std.Io.net.UnixAddress.init(sock_path);
    var waited_ms: u64 = 0;
    while (waited_ms < 2000) {
        if (ua.connect(io)) |probe_stream| {
            var s = probe_stream;
            s.close(io);
            break;
        } else |_| {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
            waited_ms += 20;
        }
    }
    if (waited_ms >= 2000) return error.DaemonStartupTimeout;
    var stream = try ua.connect(io);
    defer stream.close(io);

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var net_reader = stream.reader(io, &rbuf);
    var net_writer = stream.writer(io, &wbuf);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"definitely_not_a_method\"}";
    try net_writer.interface.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    try net_writer.interface.flush();

    const resp = try readFrame(io, &net_reader.interface, allocator);
    defer allocator.free(resp);

    // JSON-RPC §5.1 method-not-found is code -32601.
    try testing.expect(std.mem.indexOf(u8, resp, "\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "-32601") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "definitely_not_a_method") != null);
}

// ── Helpers ────────────────────────────────────────────────────────

/// Read one Content-Length-framed message from `reader`. Returns the
/// JSON body bytes — caller owns the allocation. Mirrors the core of
/// jsonrpc.readFrame but drops the duck-typed indirection so it's
/// easy to read inline.
fn readFrame(io: std.Io, reader: *std.Io.Reader, allocator: std.mem.Allocator) ![]u8 {
    _ = io;
    // Read headers until empty line.
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
