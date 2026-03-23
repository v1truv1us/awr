/// cookie.zig — RFC 6265 cookie jar.
///
/// Implements:
///   - Set-Cookie parsing (domain, path, secure, httponly, samesite, max-age)
///   - Domain suffix matching per RFC 6265 §5.1.3
///   - Serialization to Cookie: request header value
///   - Session cookie support (null expires)
///   - Expired cookie purging
///
/// NOTE: In Zig 0.15.x, std.ArrayList is the unmanaged variant.
/// All mutating methods require an explicit allocator argument.
const std = @import("std");

// ── Types ─────────────────────────────────────────────────────────────────

pub const SameSite = enum { strict, lax, none };

/// SameSite send context. Tracks whether the current request is cross-site.
pub const CookieSendContext = struct {
    /// True if the request host differs from the cookie's registered domain.
    is_cross_site: bool = false,
    /// True if this is a top-level navigation (not a sub-resource request).
    is_navigational: bool = true,
};

pub const Cookie = struct {
    name: []u8,
    value: []u8,
    domain: []u8,
    path: []u8,
    expires: ?i64,    // Unix timestamp; null = session cookie
    secure: bool,
    http_only: bool,
    same_site: SameSite,

    /// Free all owned strings.
    pub fn deinit(self: *Cookie, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        allocator.free(self.domain);
        allocator.free(self.path);
    }
};

// ── CookieJar ─────────────────────────────────────────────────────────────

pub const CookieJar = struct {
    cookies: std.ArrayList(Cookie) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CookieJar {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CookieJar) void {
        for (self.cookies.items) |*c| c.deinit(self.allocator);
        self.cookies.deinit(self.allocator);
    }

    /// Parse a Set-Cookie header value and store the cookie.
    /// `request_domain` is the effective domain when no Domain= attribute is present.
    pub fn parseSetCookie(self: *CookieJar, header_value: []const u8, request_domain: []const u8) !void {
        var it = std.mem.splitScalar(u8, header_value, ';');

        // First token: name=value
        const name_value_raw = it.next() orelse return error.InvalidCookie;
        const eq_pos = std.mem.indexOfScalar(u8, name_value_raw, '=') orelse return error.InvalidCookie;
        const name  = std.mem.trim(u8, name_value_raw[0..eq_pos], " ");
        const value = std.mem.trim(u8, name_value_raw[eq_pos + 1 ..], " ");

        var domain    = try self.allocator.dupe(u8, request_domain);
        var path      = try self.allocator.dupe(u8, "/");
        var secure    = false;
        var http_only = false;
        var same_site = SameSite.lax;
        var expires: ?i64 = null;

        // Remaining tokens: attributes
        while (it.next()) |attr_raw| {
            const attr = std.mem.trim(u8, attr_raw, " ");
            if (std.ascii.eqlIgnoreCase(attr, "secure")) {
                secure = true;
            } else if (std.ascii.eqlIgnoreCase(attr, "httponly")) {
                http_only = true;
            } else if (attrStartsWithIgnoreCase(attr, "SameSite=", 9)) {
                const sv = attr[9..];
                same_site = if (std.ascii.eqlIgnoreCase(sv, "strict")) .strict
                            else if (std.ascii.eqlIgnoreCase(sv, "none")) .none
                            else .lax;
            } else if (attrStartsWithIgnoreCase(attr, "Domain=", 7)) {
                const d = std.mem.trim(u8, attr[7..], " .");
                self.allocator.free(domain);
                domain = try self.allocator.dupe(u8, d);
            } else if (attrStartsWithIgnoreCase(attr, "Path=", 5)) {
                const p = std.mem.trim(u8, attr[5..], " ");
                self.allocator.free(path);
                path = try self.allocator.dupe(u8, p);
            } else if (attrStartsWithIgnoreCase(attr, "Max-Age=", 8)) {
                const age_str = std.mem.trim(u8, attr[8..], " ");
                const age = std.fmt.parseInt(i64, age_str, 10) catch continue;
                expires = std.time.timestamp() + age;
            }
        }

        const cookie = Cookie{
            .name      = try self.allocator.dupe(u8, name),
            .value     = try self.allocator.dupe(u8, value),
            .domain    = domain,
            .path      = path,
            .expires   = expires,
            .secure    = secure,
            .http_only = http_only,
            .same_site = same_site,
        };

        // Replace existing cookie with same name+domain+path
        for (self.cookies.items, 0..) |*existing, i| {
            if (std.mem.eql(u8, existing.name, name) and
                std.mem.eql(u8, existing.domain, domain) and
                std.mem.eql(u8, existing.path, path))
            {
                existing.deinit(self.allocator);
                self.cookies.items[i] = cookie;
                return;
            }
        }
        try self.cookies.append(self.allocator, cookie);
    }

    /// Build Cookie: header value for a request.
    /// Caller owns the returned slice.
    ///
    /// For Phase 1, treats all requests as same-site navigations.
    pub fn getCookieHeader(
        self: *CookieJar,
        request_host: []const u8,
        request_path: []const u8,
        https: bool,
    ) ![]u8 {
        return self.getCookieHeaderContext(request_host, request_path, https, .{});
    }

    /// Build Cookie: header value with explicit SameSite enforcement context.
    pub fn getCookieHeaderContext(
        self: *CookieJar,
        request_host: []const u8,
        request_path: []const u8,
        https: bool,
        ctx: CookieSendContext,
    ) ![]u8 {
        const now = std.time.timestamp();
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(self.allocator);
        var first = true;

        for (self.cookies.items) |c| {
            if (c.expires) |exp| if (exp <= now) continue;
            if (c.secure and !https) continue;
            if (!domainMatches(request_host, c.domain)) continue;
            if (!pathMatches(request_path, c.path)) continue;

            // SameSite enforcement
            switch (c.same_site) {
                .strict => {
                    // SameSite=strict: never send on cross-site requests
                    if (ctx.is_cross_site) continue;
                },
                .lax => {
                    // SameSite=lax: allow on same-site, allow on cross-site navigational GET
                    if (ctx.is_cross_site and !ctx.is_navigational) continue;
                },
                .none => {
                    // SameSite=none: always send (Secure is already checked above)
                },
            }

            if (!first) try buf.appendSlice(self.allocator, "; ");
            try buf.appendSlice(self.allocator, c.name);
            try buf.append(self.allocator, '=');
            try buf.appendSlice(self.allocator, c.value);
            first = false;
        }
        return buf.toOwnedSlice(self.allocator);
    }

    /// Remove all cookies whose Max-Age has elapsed.
    pub fn purgeExpired(self: *CookieJar) void {
        const now = std.time.timestamp();
        var i: usize = 0;
        while (i < self.cookies.items.len) {
            const c = &self.cookies.items[i];
            if (c.expires) |exp| if (exp <= now) {
                c.deinit(self.allocator);
                _ = self.cookies.swapRemove(i);
                continue;
            };
            i += 1;
        }
    }
};

// ── Helpers ────────────────────────────────────────────────────────────────

/// Case-insensitive prefix check for cookie attribute names.
fn attrStartsWithIgnoreCase(attr: []const u8, prefix: []const u8, prefix_len: usize) bool {
    if (attr.len < prefix_len) return false;
    return std.ascii.eqlIgnoreCase(attr[0..prefix_len], prefix);
}

/// RFC 6265 §5.1.4 path matching.
/// Returns true if `cookie_path` matches `request_path`.
///
/// A cookie path matches if:
///   1. The paths are equal, OR
///   2. The cookie path is a prefix of the request path AND:
///      - the cookie path ends with '/', OR
///      - the next character in the request path is '/'
///
/// This prevents /api from matching /apiOld while still allowing /api to match /api/users.
pub fn pathMatches(request_path: []const u8, cookie_path: []const u8) bool {
    // Exact match
    if (std.mem.eql(u8, request_path, cookie_path)) return true;

    // Prefix match: cookie_path must be a prefix of request_path
    if (!std.mem.startsWith(u8, request_path, cookie_path)) return false;

    // If the cookie path is "/", it always matches (it's the default root path)
    if (std.mem.eql(u8, cookie_path, "/")) return true;

    // Boundary check: cookie path must end with '/' OR next char in request must be '/'
    const next_char = request_path[cookie_path.len];
    return cookie_path[cookie_path.len - 1] == '/' or next_char == '/';
}

/// RFC 6265 §5.1.3 domain matching.
/// Matches if hosts are equal (case-insensitive) or request_host is a proper subdomain.
pub fn domainMatches(request_host: []const u8, cookie_domain: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(request_host, cookie_domain)) return true;
    if (request_host.len > cookie_domain.len + 1) {
        const offset = request_host.len - cookie_domain.len;
        if (request_host[offset - 1] == '.' and
            std.ascii.eqlIgnoreCase(request_host[offset..], cookie_domain))
            return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "parse simple name=value cookie" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("session=abc123", "example.com");
    try std.testing.expectEqual(@as(usize, 1), jar.cookies.items.len);
    try std.testing.expectEqualStrings("session", jar.cookies.items[0].name);
    try std.testing.expectEqualStrings("abc123", jar.cookies.items[0].value);
}

test "parse cookie with Domain attribute" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("id=42; Domain=example.com", "sub.example.com");
    try std.testing.expectEqualStrings("example.com", jar.cookies.items[0].domain);
}

test "parse cookie with Path attribute" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("token=xyz; Path=/api", "example.com");
    try std.testing.expectEqualStrings("/api", jar.cookies.items[0].path);
}

test "parse cookie with Secure flag" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("id=1; Secure", "example.com");
    try std.testing.expect(jar.cookies.items[0].secure);
}

test "parse cookie with HttpOnly flag" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("id=1; HttpOnly", "example.com");
    try std.testing.expect(jar.cookies.items[0].http_only);
}

test "parse cookie with SameSite=Strict" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("id=1; SameSite=Strict", "example.com");
    try std.testing.expectEqual(SameSite.strict, jar.cookies.items[0].same_site);
}

test "parse cookie with SameSite=None" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("id=1; SameSite=None", "example.com");
    try std.testing.expectEqual(SameSite.none, jar.cookies.items[0].same_site);
}

test "parse cookie with Max-Age sets future expiry" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("id=1; Max-Age=3600", "example.com");
    const c = jar.cookies.items[0];
    try std.testing.expect(c.expires != null);
    try std.testing.expect(c.expires.? > std.time.timestamp());
}

test "session cookie has null expires" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("id=1", "example.com");
    try std.testing.expectEqual(@as(?i64, null), jar.cookies.items[0].expires);
}

test "domainMatches exact match" {
    try std.testing.expect(domainMatches("example.com", "example.com"));
}

test "domainMatches subdomain match" {
    try std.testing.expect(domainMatches("sub.example.com", "example.com"));
}

test "domainMatches rejects unrelated domain" {
    try std.testing.expect(!domainMatches("evil.com", "example.com"));
}

test "domainMatches rejects suffix-but-not-subdomain (notexample.com)" {
    try std.testing.expect(!domainMatches("notexample.com", "example.com"));
}

test "pathMatches exact match" {
    try std.testing.expect(pathMatches("/api/users", "/api/users"));
}

test "pathMatches prefix with trailing slash" {
    try std.testing.expect(pathMatches("/api/users", "/api/"));
}

test "pathMatches prefix without trailing slash (boundary)" {
    try std.testing.expect(pathMatches("/api/users", "/api"));
}

test "pathMatches rejects non-boundary prefix (/api vs /apiOld)" {
    try std.testing.expect(!pathMatches("/apiOld", "/api"));
}

test "pathMatches root always matches" {
    try std.testing.expect(pathMatches("/anything/here", "/"));
}

test "pathMatches rejects different prefix (/foo vs /bar)" {
    try std.testing.expect(!pathMatches("/bar/baz", "/foo"));
}

test "pathMatches identical root" {
    try std.testing.expect(pathMatches("/", "/"));
}

test "getCookieHeader serializes matching cookies" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("a=1", "example.com");
    try jar.parseSetCookie("b=2", "example.com");
    const header = try jar.getCookieHeader("example.com", "/", false);
    defer std.testing.allocator.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "a=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "b=2") != null);
}

test "getCookieHeader excludes cookies for wrong domain" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("secret=x", "other.com");
    const header = try jar.getCookieHeader("example.com", "/", false);
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings("", header);
}

test "getCookieHeader excludes Secure cookies over plain HTTP" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("s=1; Secure", "example.com");
    const header = try jar.getCookieHeader("example.com", "/", false);
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings("", header);
}

test "getCookieHeader includes Secure cookies over HTTPS" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("s=1; Secure", "example.com");
    const header = try jar.getCookieHeader("example.com", "/", true);
    defer std.testing.allocator.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "s=1") != null);
}

test "getCookieHeader excludes cookies with non-matching path" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("api=1; Path=/api", "example.com");
    const header = try jar.getCookieHeader("example.com", "/other", false);
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings("", header);
}

test "getCookieHeader includes cookies on matching path prefix" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("api=1; Path=/api", "example.com");
    const header = try jar.getCookieHeader("example.com", "/api/users", false);
    defer std.testing.allocator.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "api=1") != null);
}

test "purgeExpired removes expired cookies" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("old=1; Max-Age=3600", "example.com");
    jar.cookies.items[0].expires = std.time.timestamp() - 1;
    try jar.parseSetCookie("fresh=2; Max-Age=3600", "example.com");
    jar.purgeExpired();
    try std.testing.expectEqual(@as(usize, 1), jar.cookies.items.len);
    try std.testing.expectEqualStrings("fresh", jar.cookies.items[0].name);
}

test "SameSite=Strict excluded on cross-site request" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("sid=1; SameSite=Strict", "example.com");
    const ctx = CookieSendContext{ .is_cross_site = true, .is_navigational = true };
    const header = try jar.getCookieHeaderContext("example.com", "/", false, ctx);
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings("", header);
}

test "SameSite=Strict included on same-site request" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("sid=1; SameSite=Strict", "example.com");
    const ctx = CookieSendContext{ .is_cross_site = false, .is_navigational = true };
    const header = try jar.getCookieHeaderContext("example.com", "/", false, ctx);
    defer std.testing.allocator.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "sid=1") != null);
}

test "SameSite=Lax included on cross-site navigational" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("sid=1; SameSite=Lax", "example.com");
    const ctx = CookieSendContext{ .is_cross_site = true, .is_navigational = true };
    const header = try jar.getCookieHeaderContext("example.com", "/", false, ctx);
    defer std.testing.allocator.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "sid=1") != null);
}

test "SameSite=Lax excluded on cross-site non-navigational" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("sid=1; SameSite=Lax", "example.com");
    const ctx = CookieSendContext{ .is_cross_site = true, .is_navigational = false };
    const header = try jar.getCookieHeaderContext("example.com", "/", false, ctx);
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings("", header);
}

test "SameSite=None always sent if secure over HTTPS" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("sid=1; SameSite=None; Secure", "example.com");
    const ctx = CookieSendContext{ .is_cross_site = true, .is_navigational = false };
    const header = try jar.getCookieHeaderContext("example.com", "/", true, ctx);
    defer std.testing.allocator.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "sid=1") != null);
}
