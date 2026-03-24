/// tls.zig — TLS connection abstraction (Phase 3 / opt-in backend).
///
/// PHASE 1 HTTPS: HTTPS fetches are handled by client.zig's fetchHttpsViaStd(),
/// which delegates to std.http.Client (backed by std.crypto.tls). TlsConn is
/// NOT used in the default Phase 1 build.
///
/// This file provides the Phase 3 TlsConn API for JA4+ fingerprint-matching TLS.
/// Two backends are selectable via -Dtls-backend at build time:
///
///   - stub (default): no native deps; all ops return CurlImpersonateNotAvailable.
///     Used in Phase 1. Tests compile and pass without any TLS library.
///   - curl_impersonate: real Chrome-impersonating TLS via the C shim.
///     Requires libcurl-impersonate-chrome. Temporary scaffold until Phase 3.
///
/// TODO(Phase 3): Replace curl_impersonate backend with owned BoringSSL stack.
///   AWR is a first-party browser — it will have its own TLS fingerprint,
///   not impersonate Chrome. curl-impersonate is only a validation scaffold.
///   See awr-spec/Phase1-Networking-TLS.md for the full decision record.
///
/// The Zig API surface is identical regardless of backend. Backend selection
/// is purely a build-time concern.

const std = @import("std");
const build_opts = @import("build_opts");
const use_curl = build_opts.tls_backend == .curl_impersonate;

/// C shim import — only compiled when curl_impersonate backend is selected.
const c = if (use_curl) @cImport({
    @cInclude("tls_curl_shim.h");
});

// ── Types ─────────────────────────────────────────────────────────────────

pub const TlsState = enum {
    handshaking,
    established,
    renegotiating,
    closed,
};

pub const HttpProtocol = enum {
    http1_1,
    http2,
};

pub const ChromeProfile = enum {
    chrome_132,
    // Future: chrome_133, edge_131, firefox_128, safari_18
};

pub const TlsError = error{
    CurlImpersonateNotAvailable,
    HandshakeFailed,
    SendFailed,
    RecvFailed,
    NotConnected,
    AlreadyClosed,
};

// ── TlsConn ───────────────────────────────────────────────────────────────

/// TLS connection. Backend-specific details are hidden behind the public API.
pub const TlsConn = struct {
    /// Impersonation target (always chrome_132 for Phase 1)
    profile: ChromeProfile,

    /// Current TLS state
    tls_state: TlsState,

    /// Protocol negotiated via ALPN (set after handshake)
    protocol: HttpProtocol,

    /// Remote hostname (for SNI)
    host: []const u8,

    /// Port
    port: u16,

    /// TLS 1.3 session ticket for 0-RTT resumption (null = no ticket yet)
    session_ticket: ?[]u8,

    allocator: std.mem.Allocator,

    /// Underlying shim context (null in stub mode).
    shim_ctx: if (use_curl) ?*c.awr_tls_ctx else void,

    /// Create a new TlsConn.
    pub fn init(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        profile: ChromeProfile,
    ) !TlsConn {
        return TlsConn{
            .profile        = profile,
            .tls_state      = .closed,
            .protocol       = .http2,
            .host           = host,
            .port           = port,
            .session_ticket = null,
            .allocator      = allocator,
            .shim_ctx       = if (use_curl) null else {},
        };
    }

    /// Perform TLS handshake.
    pub fn handshake(self: *TlsConn) TlsError!void {
        if (use_curl) {
            if (self.shim_ctx != null) {
                // Already handshook or in progress
                if (self.tls_state == .established) return;
                return TlsError.AlreadyClosed;
            }

            self.tls_state = .handshaking;

            // Allocate C string for host
            const host_c = self.allocator.dupeZ(u8, self.host) catch
                return TlsError.HandshakeFailed;
            defer self.allocator.free(host_c);

            const ctx = c.awr_tls_init(host_c.ptr, self.port);
            if (ctx == null) {
                self.tls_state = .closed;
                return TlsError.CurlImpersonateNotAvailable;
            }

            const status = c.awr_tls_handshake(ctx);
            if (status != c.AWR_TLS_OK) {
                self.tls_state = .closed;
                c.awr_tls_close(ctx);
                return TlsError.HandshakeFailed;
            }

            // Map negotiated protocol
            const negotiated = c.awr_tls_negotiated_protocol(ctx);
            self.protocol = switch (negotiated) {
                c.AWR_HTTP_1_1 => .http1_1,
                c.AWR_HTTP_2   => .http2,
                else => .http2, // default to http2 for Chrome 132
            };

            self.shim_ctx = ctx;
            self.tls_state = .established;
            return;
        }

        // Stub mode
        return TlsError.CurlImpersonateNotAvailable;
    }

    /// Send `data` over the TLS connection. Returns bytes written.
    pub fn send(self: *TlsConn, data: []const u8) TlsError!usize {
        if (self.tls_state != .established) return TlsError.NotConnected;

        if (use_curl) {
            const ctx = self.shim_ctx orelse return TlsError.NotConnected;
            const result = c.awr_tls_send(ctx, data.ptr, data.len);
            if (result < 0) return TlsError.SendFailed;
            return @intCast(result);
        }

        // Stub mode
        return TlsError.CurlImpersonateNotAvailable;
    }

    /// Receive into `buf`. Returns bytes read.
    pub fn recv(self: *TlsConn, buf: []u8) TlsError!usize {
        if (self.tls_state != .established) return TlsError.NotConnected;

        if (use_curl) {
            const ctx = self.shim_ctx orelse return TlsError.NotConnected;
            const result = c.awr_tls_recv(ctx, buf.ptr, buf.len);
            if (result < 0) return TlsError.RecvFailed;
            return @intCast(result);
        }

        // Stub mode
        return TlsError.CurlImpersonateNotAvailable;
    }

    /// Return the protocol negotiated via ALPN (after handshake).
    pub fn negotiatedProtocol(self: *const TlsConn) HttpProtocol {
        return self.protocol;
    }

    /// Close the TLS connection.
    pub fn deinit(self: *TlsConn) void {
        if (self.session_ticket) |t| self.allocator.free(t);
        self.session_ticket = null;
        self.tls_state = .closed;

        if (use_curl) {
            if (self.shim_ctx) |ctx| {
                c.awr_tls_close(ctx);
                self.shim_ctx = null;
            }
        }
    }

    /// GenericReader adapter — lets callers wrap TlsConn in a Reader
    /// (e.g. for http1.readResponse).
    pub fn readFn(self: *TlsConn, buf: []u8) TlsError!usize {
        return self.recv(buf);
    }

    /// GenericWriter adapter — lets callers wrap TlsConn in a Writer
    /// (e.g. for http1.Request.write).
    pub fn writeFn(self: *TlsConn, data: []const u8) TlsError!usize {
        return self.send(data);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "TlsConn.init creates conn with chrome_132 profile" {
    var conn = try TlsConn.init(std.testing.allocator, "example.com", 443, .chrome_132);
    defer conn.deinit();
    try std.testing.expectEqual(ChromeProfile.chrome_132, conn.profile);
}

test "TlsConn.init starts in closed state" {
    var conn = try TlsConn.init(std.testing.allocator, "example.com", 443, .chrome_132);
    defer conn.deinit();
    try std.testing.expectEqual(TlsState.closed, conn.tls_state);
}

test "TlsConn.init sets host and port" {
    var conn = try TlsConn.init(std.testing.allocator, "tls.peet.ws", 443, .chrome_132);
    defer conn.deinit();
    try std.testing.expectEqualStrings("tls.peet.ws", conn.host);
    try std.testing.expectEqual(@as(u16, 443), conn.port);
}

test "TlsConn.init has null session_ticket (no resumption yet)" {
    var conn = try TlsConn.init(std.testing.allocator, "example.com", 443, .chrome_132);
    defer conn.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), conn.session_ticket);
}

test "TlsConn.send returns NotConnected when not established" {
    var conn = try TlsConn.init(std.testing.allocator, "example.com", 443, .chrome_132);
    defer conn.deinit();
    const result = conn.send("GET / HTTP/1.1\r\n");
    try std.testing.expectError(TlsError.NotConnected, result);
}

test "TlsConn.recv returns NotConnected when not established" {
    var conn = try TlsConn.init(std.testing.allocator, "example.com", 443, .chrome_132);
    defer conn.deinit();
    var buf: [256]u8 = undefined;
    const result = conn.recv(&buf);
    try std.testing.expectError(TlsError.NotConnected, result);
}

test "TlsConn.negotiatedProtocol returns http2 by default" {
    var conn = try TlsConn.init(std.testing.allocator, "example.com", 443, .chrome_132);
    defer conn.deinit();
    try std.testing.expectEqual(HttpProtocol.http2, conn.negotiatedProtocol());
}

test "TlsConn.deinit transitions to closed state" {
    var conn = try TlsConn.init(std.testing.allocator, "example.com", 443, .chrome_132);
    conn.deinit();
    try std.testing.expectEqual(TlsState.closed, conn.tls_state);
}

test "TlsConn.handshake returns NotAvailable in stub mode" {
    var conn = try TlsConn.init(std.testing.allocator, "example.com", 443, .chrome_132);
    defer conn.deinit();
    const result = conn.handshake();
    try std.testing.expectError(TlsError.CurlImpersonateNotAvailable, result);
}

// TODO(Phase 3): Add integration test for TlsConn handshake once BoringSSL
// stack is in place. curl_impersonate integration tested via test-e2e with
// -Dtls-backend=curl_impersonate flag.
