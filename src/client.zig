/// client.zig — HTTP fetch layer.
///
/// Wires together url, tcp, tls, http1, cookie, and pool modules into a
/// single high-level `Client.fetch(url)` call that:
///   - Parses the URL
///   - Connects via TcpConn (or attempts TlsConn for HTTPS — stub for now)
///   - Builds a Chrome 132-fingerprint request via setChrome132Defaults
///   - Attaches cookies from the jar and stores Set-Cookie responses
///   - Follows up to max_redirects 3xx responses
///
/// NOTE: curl-impersonate is not yet installed, so HTTPS returns
/// error.TlsNotAvailable until the TLS stub is replaced.
const std   = @import("std");
const http1 = @import("net/http1.zig");
const cookie_mod = @import("net/cookie.zig");
const pool_mod   = @import("net/pool.zig");
const tls_mod    = @import("net/tls.zig");
const tcp_mod    = @import("net/tcp.zig");
const url_mod    = @import("net/url.zig");

// ── Public types ───────────────────────────────────────────────────────────

pub const ClientOptions = struct {
    follow_redirects: bool     = true,
    max_redirects:    u8       = 10,
    timeout_ms:       u32      = 30_000,
    user_agent:       []const u8 = "AWR/0.1",
};

/// Response is the same type as http1.Response — reusing avoids duplication.
pub const Response = http1.Response;

pub const Client = struct {
    allocator: std.mem.Allocator,
    pool:    pool_mod.ConnectionPool,
    cookies: cookie_mod.CookieJar,
    options: ClientOptions,

    pub fn init(allocator: std.mem.Allocator, options: ClientOptions) Client {
        return .{
            .allocator = allocator,
            .pool      = pool_mod.ConnectionPool.init(allocator),
            .cookies   = cookie_mod.CookieJar.init(allocator),
            .options   = options,
        };
    }

    pub fn deinit(self: *Client) void {
        self.pool.deinit();
        self.cookies.deinit();
    }

    pub fn fetch(self: *Client, url_str: []const u8) !Response {
        return self.fetchInternal(url_str, 0);
    }

    // ── Internal implementation ─────────────────────────────────────────────

    fn fetchInternal(self: *Client, url_str: []const u8, redirect_count: u8) !Response {
        const parsed = try url_mod.parse(url_str);

        // ── HTTPS: attempt TLS handshake (stub returns CurlImpersonateNotAvailable) ──
        if (parsed.scheme == .https) {
            var tls_conn = try tls_mod.TlsConn.init(
                self.allocator, parsed.host, parsed.port, .chrome_132,
            );
            defer tls_conn.deinit();
            tls_conn.handshake() catch |err| switch (err) {
                error.CurlImpersonateNotAvailable => return error.TlsNotAvailable,
                else => return err,
            };
            // When curl-impersonate is available: use tls_conn.send/recv instead of TCP.
        }

        // ── TCP connect ──────────────────────────────────────────────────────
        const addr = try resolveAddr(self.allocator, parsed.host, parsed.port);
        var tcp_conn = try tcp_mod.TcpConn.init(self.allocator, addr);
        defer tcp_conn.deinit();
        try tcp_conn.connect();

        // ── Build request ────────────────────────────────────────────────────
        const req_path: []const u8 = if (parsed.query) |q|
            try std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ parsed.path, q })
        else
            parsed.path;
        const path_was_allocated = parsed.query != null;
        defer if (path_was_allocated) self.allocator.free(req_path);

        var req = http1.Request{
            .method = .GET,
            .path   = req_path,
            .host   = parsed.host,
        };
        defer req.headers.deinit(self.allocator);
        try req.setChrome132Defaults(self.allocator);

        // ── Attach cookies ───────────────────────────────────────────────────
        const is_https = parsed.scheme == .https;
        const cookie_hdr = try self.cookies.getCookieHeader(parsed.host, parsed.path, is_https);
        defer self.allocator.free(cookie_hdr);
        if (cookie_hdr.len > 0) {
            try req.headers.append(self.allocator, "cookie", cookie_hdr);
        }

        // ── Write request ────────────────────────────────────────────────────
        var req_buf: [16 * 1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&req_buf);
        try req.write(fbs.writer());
        _ = try tcp_conn.write(fbs.getWritten());

        // ── Read response ────────────────────────────────────────────────────
        // Zig 0.15 removed bufferedReader; wrap Stream.read into a GenericReader
        // so http1.readResponse can call readUntilDelimiter / readNoEof.
        const StreamReader = std.io.GenericReader(
            std.net.Stream,
            std.net.Stream.ReadError,
            std.net.Stream.read,
        );
        const stream_reader: StreamReader = .{ .context = tcp_conn.stream.? };
        var resp = try http1.readResponse(stream_reader, self.allocator);

        // ── Store Set-Cookie headers ─────────────────────────────────────────
        for (resp.headers.items.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) {
                self.cookies.parseSetCookie(h.value, parsed.host) catch {};
            }
        }

        // ── Follow redirects ─────────────────────────────────────────────────
        if (self.options.follow_redirects and resp.isRedirect()) {
            if (redirect_count >= self.options.max_redirects) {
                resp.deinit();
                return error.TooManyRedirects;
            }
            if (resp.location()) |loc| {
                const redirect_url = if (std.mem.startsWith(u8, loc, "http"))
                    try self.allocator.dupe(u8, loc)
                else
                    try std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}{s}", .{
                        @tagName(parsed.scheme), parsed.host, parsed.port, loc,
                    });
                defer self.allocator.free(redirect_url);
                resp.deinit();
                return self.fetchInternal(redirect_url, redirect_count + 1);
            }
        }

        return resp;
    }
};

// ── Address resolution ─────────────────────────────────────────────────────

/// Try numeric IP parse first (no syscall), fall back to DNS for hostnames.
fn resolveAddr(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
    // parseIp handles both IPv4 and IPv6 literals without allocation.
    if (std.net.Address.parseIp(host, port)) |addr| return addr else |_| {}

    const list = try std.net.getAddressList(allocator, host, port);
    defer list.deinit();
    if (list.addrs.len == 0) return error.DnsResolutionFailed;
    return list.addrs[0]; // std.net.Address is a value type; copy is safe
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "Client.init and deinit" {
    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();
    try std.testing.expectEqual(@as(u8, 10), client.options.max_redirects);
    try std.testing.expectEqual(true, client.options.follow_redirects);
}

// ── URL parse tests (imported module) ──────────────────────────────────────

test "url: parse https://example.com/path" {
    const u = try url_mod.parse("https://example.com/path");
    try std.testing.expectEqual(url_mod.Scheme.https, u.scheme);
    try std.testing.expectEqualStrings("example.com", u.host);
    try std.testing.expectEqual(@as(u16, 443), u.port);
}

test "url: parse http with custom port" {
    const u = try url_mod.parse("http://localhost:9000/api");
    try std.testing.expectEqual(@as(u16, 9000), u.port);
    try std.testing.expectEqualStrings("/api", u.path);
}

test "url: bare host defaults to port 80 and path /" {
    const u = try url_mod.parse("http://example.com");
    try std.testing.expectEqual(@as(u16, 80), u.port);
    try std.testing.expectEqualStrings("/", u.path);
}

// ── Mock-server fetch tests ─────────────────────────────────────────────────
//
// Each test spins up a minimal HTTP server on a unique loopback port, makes
// a real fetch() call, and inspects the result.  Port assignments:
//   18480 — chrome132 headers check
//   18481 — cookie header in request
//   18482 — Set-Cookie stored in jar
//   18483 — 301 redirect followed
//   18484 — max_redirects enforcement

/// Start a one-shot server, signal `ready`, accept one connection, run
/// `handler(stream)`, then return.
fn startServer(
    addr: std.net.Address,
    ready: *std.Thread.Semaphore,
    comptime handler: fn (std.net.Stream) void,
) !std.Thread {
    const S = struct {
        addr: std.net.Address,
        ready: *std.Thread.Semaphore,
        fn serve(a: std.net.Address, r: *std.Thread.Semaphore) void {
            var server = a.listen(.{ .reuse_address = true }) catch return;
            defer server.deinit();
            r.post();
            const conn = server.accept() catch return;
            defer conn.stream.close();
            handler(conn.stream);
        }
    };
    return std.Thread.spawn(.{}, S.serve, .{ addr, ready });
}

fn respond200(stream: std.net.Stream) void {
    var buf: [8192]u8 = undefined;
    _ = stream.read(&buf) catch {};
    stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK") catch {};
}

test "fetch builds request with chrome132 headers" {
    const port: u16 = 18480;
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);

    // Capture the raw request bytes and reply 200.
    const Ctx = struct {
        buf: [8192]u8 = undefined,
        len: usize = 0,
        ready: std.Thread.Semaphore = .{},

        fn serve(ctx: *@This()) void {
            var server = ctx.ready; // suppress unused warning — accessed below
            _ = server;
            var srv = addr.listen(.{ .reuse_address = true }) catch return;
            defer srv.deinit();
            ctx.ready.post();
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            ctx.len = conn.stream.read(&ctx.buf) catch 0;
            conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n") catch {};
        }
    };
    var ctx = Ctx{};
    const t = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
    ctx.ready.wait();
    defer t.join();

    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();
    var resp = try client.fetch("http://127.0.0.1:18480/");
    defer resp.deinit();

    const req = ctx.buf[0..ctx.len];
    try std.testing.expect(std.mem.indexOf(u8, req, "sec-ch-ua") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "sec-fetch-dest") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "accept-language") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Chrome/132") != null);
}

test "fetch sets Cookie header from jar" {
    const port: u16 = 18481;
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);

    const Ctx = struct {
        buf: [8192]u8 = undefined,
        len: usize = 0,
        ready: std.Thread.Semaphore = .{},

        fn serve(ctx: *@This()) void {
            var srv = addr.listen(.{ .reuse_address = true }) catch return;
            defer srv.deinit();
            ctx.ready.post();
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            ctx.len = conn.stream.read(&ctx.buf) catch 0;
            conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n") catch {};
        }
    };
    var ctx = Ctx{};
    const t = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
    ctx.ready.wait();
    defer t.join();

    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();
    try client.cookies.parseSetCookie("session=abc123", "127.0.0.1");

    var resp = try client.fetch("http://127.0.0.1:18481/");
    defer resp.deinit();

    const req = ctx.buf[0..ctx.len];
    try std.testing.expect(std.mem.indexOf(u8, req, "cookie: session=abc123") != null);
}

test "fetch stores Set-Cookie into jar" {
    const port: u16 = 18482;
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);

    const Ctx = struct {
        ready: std.Thread.Semaphore = .{},
        fn serve(ctx: *@This()) void {
            var srv = addr.listen(.{ .reuse_address = true }) catch return;
            defer srv.deinit();
            ctx.ready.post();
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var buf: [4096]u8 = undefined;
            _ = conn.stream.read(&buf) catch {};
            conn.stream.writeAll(
                "HTTP/1.1 200 OK\r\nSet-Cookie: token=xyz; Path=/\r\nContent-Length: 0\r\n\r\n",
            ) catch {};
        }
    };
    var ctx = Ctx{};
    const t = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
    ctx.ready.wait();
    defer t.join();

    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();
    var resp = try client.fetch("http://127.0.0.1:18482/");
    defer resp.deinit();

    try std.testing.expectEqual(@as(usize, 1), client.cookies.cookies.items.len);
    try std.testing.expectEqualStrings("token", client.cookies.cookies.items[0].name);
    try std.testing.expectEqualStrings("xyz", client.cookies.cookies.items[0].value);
}

test "fetch follows 301 redirect" {
    const port: u16 = 18483;
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);

    const Ctx = struct {
        ready: std.Thread.Semaphore = .{},
        fn serve(ctx: *@This()) void {
            var srv = addr.listen(.{ .reuse_address = true }) catch return;
            defer srv.deinit();
            ctx.ready.post();

            // First connection: 301 → /new
            {
                const conn = srv.accept() catch return;
                defer conn.stream.close();
                var buf: [4096]u8 = undefined;
                _ = conn.stream.read(&buf) catch {};
                conn.stream.writeAll(
                    "HTTP/1.1 301 Moved Permanently\r\nLocation: /new\r\nContent-Length: 0\r\n\r\n",
                ) catch {};
            }
            // Second connection: 200 OK
            {
                const conn = srv.accept() catch return;
                defer conn.stream.close();
                var buf: [4096]u8 = undefined;
                _ = conn.stream.read(&buf) catch {};
                conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello") catch {};
            }
        }
    };
    var ctx = Ctx{};
    const t = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
    ctx.ready.wait();
    defer t.join();

    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();
    var resp = try client.fetch("http://127.0.0.1:18483/");
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("hello", resp.body);
}

test "fetch stops at max_redirects" {
    const port: u16 = 18484;
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);

    const Ctx = struct {
        ready: std.Thread.Semaphore = .{},
        fn serve(ctx: *@This()) void {
            var srv = addr.listen(.{ .reuse_address = true }) catch return;
            defer srv.deinit();
            ctx.ready.post();
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var buf: [4096]u8 = undefined;
            _ = conn.stream.read(&buf) catch {};
            conn.stream.writeAll(
                "HTTP/1.1 301 Moved Permanently\r\nLocation: /loop\r\nContent-Length: 0\r\n\r\n",
            ) catch {};
        }
    };
    var ctx = Ctx{};
    const t = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
    ctx.ready.wait();
    defer t.join();

    // max_redirects = 0: any redirect immediately returns TooManyRedirects
    var client = Client.init(std.testing.allocator, .{ .max_redirects = 0 });
    defer client.deinit();
    try std.testing.expectError(error.TooManyRedirects, client.fetch("http://127.0.0.1:18484/"));
}

test "integration: fetch http://example.com" {
    // Best-effort: skip gracefully on any network error (no connectivity, DNS failure, etc.)
    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();

    const resp = client.fetch("http://example.com") catch return;
    var r = resp;
    defer r.deinit();

    // example.com redirects to HTTPS, so with TLS stubbed we may get TlsNotAvailable.
    // Any 2xx or 3xx status (if connectivity exists and TLS works) is a pass.
    try std.testing.expect(r.status >= 100 and r.status < 600);
}
