/// tls.zig — TLS connection via curl-impersonate.
///
/// curl-impersonate patches libcurl to emit a browser-identical TLS ClientHello.
/// The Chrome 132 profile produces JA4+ = t13d1517h2_8daaf6152771_b6f405a00624.
///
/// INSTALLATION REQUIRED:
///   curl-impersonate is NOT installed on this system.
///   Install via:
///     macOS:  brew install curl-impersonate  (if available)
///     or build from source: https://github.com/lwthiker/curl-impersonate
///
///   After installation, set CURL_IMPERSONATE_LIB to the path of
///   libcurl-impersonate-chrome.a (or .dylib) in build.zig.
///
// TODO(Phase 3): Replace with owned BoringSSL stack. See awr-spec/Phase1-Networking-TLS.md — AWR is a first-party browser, not a Chrome impersonator.
/// TODO(curl-impersonate): Replace stub implementation with real C-ABI wrapper
///   when libcurl-impersonate is available at:
///     /usr/local/lib/libcurl-impersonate-chrome.{a,dylib}
///     /opt/homebrew/lib/libcurl-impersonate-chrome.{a,dylib}
///
/// The stub models the correct API surface so that:
///   1. All other modules compile and test successfully without curl-impersonate.
///   2. The integration is a drop-in: replace the stub body with @cImport calls.
const std = @import("std");

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

/// TLS connection wrapping curl-impersonate.
///
/// TODO(curl-impersonate): Replace `curl_handle: ?*anyopaque` with the real
/// `curl: *curl_impersonate.CURL` from the @cImport wrapper.
pub const TlsConn = struct {
    /// Opaque curl handle (null = stub mode; real = *CURL from curl_easy_init())
    curl_handle: ?*anyopaque,

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
    /// TODO(curl-impersonate): Populate from CURLINFO_TLS_SESSION after handshake
    session_ticket: ?[]u8,

    allocator: std.mem.Allocator,

    /// Create a new TlsConn in stub mode.
    /// TODO(curl-impersonate): Call curl_easy_init() here.
    pub fn init(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        profile: ChromeProfile,
    ) !TlsConn {
        return TlsConn{
            .curl_handle  = null, // TODO(curl-impersonate): = curl_easy_init()
            .profile      = profile,
            .tls_state    = .closed,
            .protocol     = .http2, // default; overridden by ALPN after handshake
            .host         = host,
            .port         = port,
            .session_ticket = null,
            .allocator    = allocator,
        };
    }

    /// Perform TLS handshake.
    /// TODO(curl-impersonate): Call curl_easy_impersonate(handle, "chrome132", 0)
    ///   then curl_easy_setopt(CURLOPT_URL, ...) and curl_easy_perform().
    pub fn handshake(self: *TlsConn) TlsError!void {
        if (self.curl_handle != null) {
            // Real implementation: invoke curl_easy_impersonate + curl_easy_perform
            return TlsError.HandshakeFailed;
        }
        // Stub: always return NotAvailable so tests can detect stub mode
        return TlsError.CurlImpersonateNotAvailable;
        // TODO: integration test, requires curl-impersonate
    }

    /// Send `data` over the TLS connection. Returns bytes written.
    /// TODO(curl-impersonate): Write to the curl connection via callback.
    pub fn send(self: *TlsConn, data: []const u8) TlsError!usize {
        if (self.tls_state != .established) return TlsError.NotConnected;
        _ = data;
        return TlsError.CurlImpersonateNotAvailable;
        // TODO: integration test, requires curl-impersonate
    }

    /// Receive into `buf`. Returns bytes read.
    /// TODO(curl-impersonate): Read from curl's write callback buffer.
    pub fn recv(self: *TlsConn, buf: []u8) TlsError!usize {
        if (self.tls_state != .established) return TlsError.NotConnected;
        _ = buf;
        return TlsError.CurlImpersonateNotAvailable;
        // TODO: integration test, requires curl-impersonate
    }

    /// Return the protocol negotiated via ALPN (after handshake).
    pub fn negotiatedProtocol(self: *const TlsConn) HttpProtocol {
        return self.protocol;
    }

    /// Close the TLS connection.
    /// TODO(curl-impersonate): Call curl_easy_cleanup(handle).
    pub fn deinit(self: *TlsConn) void {
        if (self.session_ticket) |t| self.allocator.free(t);
        self.tls_state = .closed;
        // TODO(curl-impersonate): curl_easy_cleanup(self.curl_handle);
        self.curl_handle = null;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────
//
// Tests here verify struct initialization, profile constants, and state
// transitions in stub mode. All live-network tests are marked:
//   // TODO: integration test, requires curl-impersonate

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

test "TlsConn.handshake returns CurlImpersonateNotAvailable in stub mode" {
    var conn = try TlsConn.init(std.testing.allocator, "example.com", 443, .chrome_132);
    defer conn.deinit();
    const result = conn.handshake();
    try std.testing.expectError(TlsError.CurlImpersonateNotAvailable, result);
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

// TODO: integration test, requires curl-impersonate
// test "TlsConn handshakes with tls.peet.ws and returns JA4+ = t13d1517h2_8daaf6152771_b6f405a00624" {
//     var conn = try TlsConn.init(std.testing.allocator, "tls.peet.ws", 443, .chrome_132);
//     defer conn.deinit();
//     try conn.handshake();
//     // ... fetch /api/all, assert ja4 field
// }
