/// mock.zig — a tiny static HTTP server for exercising AWR against a
/// real TCP socket.
///
/// Scope is intentionally minimal: serve files from `experiments/`
/// over HTTP/1.1 so `awr tools http://localhost:PORT/webmcp_mock.html`
/// exercises the full fetch path. Not a general-purpose webserver —
/// no chunked encoding, no compression, no keep-alive, no HTTPS,
/// no directory index.
const std = @import("std");

const READ_BUFFER_BYTES: usize = 16 * 1024;
const WRITE_BUFFER_BYTES: usize = 8 * 1024;
const MAX_FILE_BYTES: usize = 16 * 1024 * 1024;

/// Run the mock server on `host:port`, serving files rooted at `root_dir`
/// (a relative path like `"experiments"` resolves against cwd).
///
/// Blocks the caller until SIGINT / SIGTERM. Each connection is served
/// synchronously; that's fine for the demo use case (one agent, one
/// request at a time).
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    root_dir: []const u8,
) !void {
    const addr = try parseIpv4(host, port);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{
        .reuse_address = true,
    });
    defer server.deinit(io);

    // Log startup banner to stderr so stdout remains clean for callers
    // that pipe mock output through jq.
    log("awr-mock: listening on http://{s}:{d}/ root={s}", .{ host, port, root_dir });

    while (true) {
        var stream = server.accept(io) catch |err| {
            log("awr-mock: accept failed: {t}", .{err});
            continue;
        };
        defer stream.close(io);

        handleConnection(allocator, io, &stream, root_dir) catch |err| {
            log("awr-mock: connection error: {t}", .{err});
        };
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    root_dir: []const u8,
) !void {
    const read_buf = try allocator.alloc(u8, READ_BUFFER_BYTES);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, WRITE_BUFFER_BYTES);
    defer allocator.free(write_buf);

    var reader = stream.reader(io, read_buf);
    var writer = stream.writer(io, write_buf);

    var server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => return err,
    };

    log("awr-mock: {s} {s}", .{ @tagName(request.head.method), request.head.target });

    // Cookie test fixtures — present only because the daemon's
    // per-scope jar tests need a server that emits Set-Cookie and
    // echoes received Cookie: headers. Routed BEFORE the static-file
    // path so /set-cookie/... and /show-cookie/... never fall through
    // to a file lookup.
    if (handleCookieFixtures(allocator, &request)) |handled| {
        if (handled) return;
    } else |err| {
        log("awr-mock: cookie fixture error: {t}", .{err});
        return;
    }

    const path = sanitizeTarget(request.head.target);
    const body = readFileUnder(allocator, root_dir, path, io) catch |err| switch (err) {
        error.FileNotFound => {
            try request.respond("404 Not Found\n", .{
                .status = .not_found,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                },
            });
            return;
        },
        else => {
            try request.respond("500 Internal Server Error\n", .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                },
            });
            return;
        },
    };
    defer allocator.free(body);

    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = mimeFor(path) },
        },
    });
}

/// Cookie test fixtures: `/set-cookie/<name>/<value>` emits a Set-Cookie
/// header; `/show-cookie/<name>` returns the value of the `<name>` cookie
/// from the request's `Cookie:` header (empty if absent). Returns
/// `true` when a fixture path matched and the request was answered;
/// `false` to fall through to the static-file path.
///
/// These exist only to make the daemon's per-scope jar persistence
/// integration test possible — without them the test could only
/// verify *empty* jar files exist on disk, not that real cookies
/// round-trip through the daemon's CookieJar.
fn handleCookieFixtures(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
) !bool {
    const target = request.head.target;
    // Strip the query string for matching; we don't accept query
    // params on these fixtures.
    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = if (q) |i| target[0..i] else target;

    if (std.mem.startsWith(u8, path, "/set-cookie/")) {
        const rest = path["/set-cookie/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse {
            try request.respond("usage: /set-cookie/<name>/<value>\n", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                },
            });
            return true;
        };
        const name = rest[0..slash];
        const value = rest[slash + 1 ..];
        if (name.len == 0 or !isCookieToken(name) or !isCookieValue(value)) {
            try request.respond("invalid cookie name/value\n", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                },
            });
            return true;
        }
        // Max-Age=3600 makes this a persistent cookie (not session) so
        // it survives the daemon's per-request Page deinit→init cycle
        // through the on-disk jar. Session cookies (no Max-Age/Expires)
        // are intentionally skipped by the Netscape-format serializer
        // — that's correct browser behavior, but it would mean this
        // fixture can't verify disk persistence without an explicit
        // lifetime.
        const set_cookie = try std.fmt.allocPrint(
            allocator,
            "{s}={s}; Max-Age=3600; Path=/",
            .{ name, value },
        );
        defer allocator.free(set_cookie);
        const body = try std.fmt.allocPrint(allocator, "set {s}={s}\n", .{ name, value });
        defer allocator.free(body);
        try request.respond(body, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                .{ .name = "set-cookie", .value = set_cookie },
            },
        });
        return true;
    }

    if (std.mem.startsWith(u8, path, "/show-cookie/")) {
        const name = path["/show-cookie/".len..];
        if (name.len == 0 or !isCookieToken(name)) {
            try request.respond("usage: /show-cookie/<name>\n", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                },
            });
            return true;
        }
        const cookie_header = findHeader(request, "cookie") orelse "";
        const value = extractCookieValue(cookie_header, name) orelse "";
        // Body shape: `<name>=<value>` (or `<name>=` when not present).
        // Lets the integration test assert with a single substring search.
        const body = try std.fmt.allocPrint(allocator, "{s}={s}\n", .{ name, value });
        defer allocator.free(body);
        try request.respond(body, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
            },
        });
        return true;
    }

    return false;
}

/// Find a request header by lowercase name. std.http.Server doesn't
/// expose a get-by-name helper on Request.head, so we iterate.
fn findHeader(request: *std.http.Server.Request, name_lower: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name_lower)) return h.value;
    }
    return null;
}

/// Extract the value of `<name>` from a Cookie header value like
/// `a=1; b=2; <name>=<value>`. Returns null when not present.
/// Whitespace around `;`-separated pairs is tolerated.
fn extractCookieValue(cookie_header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, cookie_header, ';');
    while (it.next()) |raw_pair| {
        const pair = std.mem.trim(u8, raw_pair, " \t");
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        const v = pair[eq + 1 ..];
        if (std.mem.eql(u8, k, name)) return v;
    }
    return null;
}

/// RFC 6265 token chars (a tiny subset is sufficient for tests).
fn isCookieToken(s: []const u8) bool {
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

/// Cookie value: same allowed set as token + a few common chars,
/// excluding `;` and whitespace. Tightened from RFC 6265 §4.1 to
/// what we actually emit from tests.
fn isCookieValue(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.', ':' => {},
        else => return false,
    };
    return true;
}

/// Strip the query string, drop any leading `/`, and reject paths that
/// try to escape the serving root via `..` segments.
fn sanitizeTarget(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?');
    const raw = if (q) |i| target[0..i] else target;
    const trimmed = if (raw.len > 0 and raw[0] == '/') raw[1..] else raw;
    // Reject `..` segments; a defence-in-depth check — the path is later
    // resolved against `root_dir` with `std.Io.Dir.openDir(root_dir)` so
    // traversal out of root would fail anyway, but an explicit reject
    // keeps the failure mode clean.
    var it = std.mem.tokenizeScalar(u8, trimmed, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return "";
    }
    // Default to webmcp_mock.html when the client asks for the root.
    if (trimmed.len == 0) return "webmcp_mock.html";
    return trimmed;
}

fn readFileUnder(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    rel_path: []const u8,
    io: std.Io,
) ![]u8 {
    if (rel_path.len == 0) return error.FileNotFound;
    // Resolve `root_dir/rel_path` via cwd; simple string join keeps the
    // dependency surface small and matches how loadPage reads fixtures.
    const joined = try std.fs.path.join(allocator, &.{ root_dir, rel_path });
    defer allocator.free(joined);
    return std.Io.Dir.cwd().readFileAlloc(io, joined, allocator, .limited(MAX_FILE_BYTES));
}

fn mimeFor(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".htm"))
        return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".txt")) return "text/plain; charset=utf-8";
    return "application/octet-stream";
}

fn parseIpv4(host: []const u8, port: u16) !std.Io.net.IpAddress {
    return std.Io.net.IpAddress.parseIp4(host, port);
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "sanitizeTarget strips query + leading slash" {
    try std.testing.expectEqualStrings("webmcp_mock.html", sanitizeTarget("/webmcp_mock.html"));
    try std.testing.expectEqualStrings("webmcp_mock.html", sanitizeTarget("/webmcp_mock.html?x=1"));
    try std.testing.expectEqualStrings("webmcp_mock.html", sanitizeTarget("/"));
    try std.testing.expectEqualStrings("", sanitizeTarget("/../etc/passwd"));
    try std.testing.expectEqualStrings("", sanitizeTarget("/a/../b"));
}

test "mimeFor picks html/js/json" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeFor("a.html"));
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", mimeFor("tools.js"));
    try std.testing.expectEqualStrings("application/json; charset=utf-8", mimeFor("data.json"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeFor("binary"));
}

test "extractCookieValue finds named cookie ignoring whitespace" {
    try std.testing.expectEqualStrings("abc", extractCookieValue("sid=abc", "sid").?);
    try std.testing.expectEqualStrings("abc", extractCookieValue("a=1; sid=abc; b=2", "sid").?);
    try std.testing.expectEqualStrings("abc", extractCookieValue(" sid=abc ", "sid").?);
    try std.testing.expectEqual(@as(?[]const u8, null), extractCookieValue("a=1; b=2", "sid"));
    try std.testing.expectEqual(@as(?[]const u8, null), extractCookieValue("", "sid"));
}

test "isCookieToken / isCookieValue accept safe chars only" {
    try std.testing.expect(isCookieToken("sid"));
    try std.testing.expect(isCookieToken("session_id-1.0"));
    try std.testing.expect(!isCookieToken("a;b"));
    try std.testing.expect(!isCookieToken("a b"));
    try std.testing.expect(isCookieValue("abc123"));
    try std.testing.expect(!isCookieValue(""));
    try std.testing.expect(!isCookieValue("a;b"));
    try std.testing.expect(!isCookieValue("a b"));
}
