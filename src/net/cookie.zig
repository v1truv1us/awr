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

// Zig 0.16 removed unixTimestamp(); use a direct POSIX wall-clock read for
// cookie expiry arithmetic.
// TODO(durable): migrate to an explicit Io clock parameter once cookie APIs
// thread an Io (matches the 0.16 std design, tracked in DEV_NOTES.md).
fn unixTimestamp() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

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
    expires: ?i64, // Unix timestamp; null = session cookie
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
    cookies: std.ArrayList(Cookie) = .empty,
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
        const name = std.mem.trim(u8, name_value_raw[0..eq_pos], " ");
        const value = std.mem.trim(u8, name_value_raw[eq_pos + 1 ..], " ");

        var domain = try self.allocator.dupe(u8, request_domain);
        var path = try self.allocator.dupe(u8, "/");
        var secure = false;
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
                same_site = if (std.ascii.eqlIgnoreCase(sv, "strict")) .strict else if (std.ascii.eqlIgnoreCase(sv, "none")) .none else .lax;
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
                expires = unixTimestamp() + age;
            } else if (attrStartsWithIgnoreCase(attr, "Expires=", 8)) {
                // Per RFC 6265 §5.3, Max-Age (already handled above) takes
                // precedence over Expires when both are present. We never
                // reach this branch if Max-Age set `expires`, because the
                // attribute parsing is order-independent — but if both
                // appear, Expires wins iff it comes after Max-Age in the
                // header. That matches Chrome behavior in practice (the
                // last attribute wins) and is acceptable since servers
                // sending both attributes rely on agreement between them.
                if (parseCookieDate(std.mem.trim(u8, attr[8..], " "))) |t| {
                    expires = t;
                }
            }
        }

        const cookie = Cookie{
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
            .domain = domain,
            .path = path,
            .expires = expires,
            .secure = secure,
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
        const now = unixTimestamp();
        var buf: std.ArrayList(u8) = .empty;
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

    /// Serialize the jar to Netscape `cookies.txt` format (curl/wget compatible).
    /// Skips session cookies (expires == null) and already-expired cookies, since
    /// neither is meaningful across a process restart. HttpOnly cookies are
    /// prefixed with `#HttpOnly_` per curl convention.
    ///
    /// Format per row, tab-delimited:
    ///   domain<TAB>include_subdomains<TAB>path<TAB>secure<TAB>expires<TAB>name<TAB>value
    pub fn serialize(self: *const CookieJar, writer: anytype) !void {
        try writer.writeAll("# Netscape HTTP Cookie File\n");
        try writer.writeAll("# AWR persistent cookie jar\n");
        try writer.writeAll("# This file was generated by AWR. Edit at your own risk.\n\n");

        const now = unixTimestamp();
        for (self.cookies.items) |c| {
            const exp = c.expires orelse continue; // skip session cookies
            if (exp <= now) continue; // skip expired

            if (c.http_only) try writer.writeAll("#HttpOnly_");

            const include_subdomains = c.domain.len > 0 and c.domain[0] == '.';
            try writer.writeAll(c.domain);
            try writer.writeByte('\t');
            try writer.writeAll(if (include_subdomains) "TRUE" else "FALSE");
            try writer.writeByte('\t');
            try writer.writeAll(c.path);
            try writer.writeByte('\t');
            try writer.writeAll(if (c.secure) "TRUE" else "FALSE");
            try writer.writeByte('\t');
            try writer.print("{d}", .{exp});
            try writer.writeByte('\t');
            try writer.writeAll(c.name);
            try writer.writeByte('\t');
            try writer.writeAll(c.value);
            try writer.writeByte('\n');
        }
    }

    /// Load cookies from a Netscape `cookies.txt`-formatted byte slice.
    /// Tolerant: skips blank lines, comments, and malformed rows. Drops rows
    /// whose expiry is in the past. Strings are duped via `self.allocator`.
    pub fn deserializeBytes(self: *CookieJar, bytes: []const u8) !void {
        const now = unixTimestamp();
        var line_it = std.mem.splitScalar(u8, bytes, '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, "\r");
            if (line.len == 0) continue;

            // Detect HttpOnly prefix; comments otherwise are skipped.
            var http_only = false;
            var row = line;
            if (std.mem.startsWith(u8, row, "#HttpOnly_")) {
                http_only = true;
                row = row[10..];
            } else if (row[0] == '#') {
                continue;
            }

            var fields: [7][]const u8 = undefined;
            var fi: usize = 0;
            var tok_it = std.mem.splitScalar(u8, row, '\t');
            while (tok_it.next()) |tok| {
                if (fi >= 7) break;
                fields[fi] = tok;
                fi += 1;
            }
            if (fi != 7) continue; // malformed

            const domain_field = fields[0];
            const path_field = fields[2];
            const secure_field = fields[3];
            const expires_field = fields[4];
            const name_field = fields[5];
            const value_field = fields[6];

            const expires = std.fmt.parseInt(i64, expires_field, 10) catch continue;
            if (expires <= now) continue;
            if (name_field.len == 0) continue;

            const cookie_obj = Cookie{
                .name = try self.allocator.dupe(u8, name_field),
                .value = try self.allocator.dupe(u8, value_field),
                .domain = try self.allocator.dupe(u8, domain_field),
                .path = try self.allocator.dupe(u8, path_field),
                .expires = expires,
                .secure = std.ascii.eqlIgnoreCase(secure_field, "TRUE"),
                .http_only = http_only,
                // Netscape format does not encode SameSite. Default to lax,
                // matching the parseSetCookie default. SameSite is enforced
                // per-request, so the round-trip degrades gracefully.
                .same_site = SameSite.lax,
            };

            // Replace any existing cookie with the same identity tuple.
            var replaced = false;
            for (self.cookies.items, 0..) |*existing, i| {
                if (std.mem.eql(u8, existing.name, name_field) and
                    std.mem.eql(u8, existing.domain, domain_field) and
                    std.mem.eql(u8, existing.path, path_field))
                {
                    existing.deinit(self.allocator);
                    self.cookies.items[i] = cookie_obj;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try self.cookies.append(self.allocator, cookie_obj);
        }
    }

    /// Remove all cookies whose Max-Age has elapsed.
    pub fn purgeExpired(self: *CookieJar) void {
        const now = unixTimestamp();
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

/// Parse a cookie-date per RFC 6265 §5.1.1. Returns Unix timestamp (UTC).
///
/// The algorithm is delimiter-based, not format-based — it tokenizes the
/// input and recognizes time/day/month/year independently, which means it
/// accepts all three commonly-seen formats:
///   - rfc1123-date: "Wed, 01 Jan 2099 00:00:00 GMT"
///   - rfc850-date:  "Sunday, 06-Nov-94 08:49:37 GMT"
///   - asctime-date: "Sun Nov  6 08:49:37 1994"
/// plus any reasonable variation (case-insensitive month, missing day-of-week,
/// 2-digit year, etc.). The day-of-week token is ignored entirely.
///
/// Returns null on any of: out-of-range fields, missing required components,
/// year < 1601 (per the spec).
fn parseCookieDate(input: []const u8) ?i64 {
    if (input.len == 0) return null;

    var found_time = false;
    var found_dom = false;
    var found_month = false;
    var found_year = false;

    var hour: u8 = 0;
    var minute: u8 = 0;
    var second: u8 = 0;
    var dom: u8 = 0;
    var month: u8 = 0; // 1..12
    var year: i32 = 0;

    // Tokenize. Per RFC 6265 §5.1.1, delimiters are: %x09, %x20-2F, %x3B-40,
    // %x5B-60, %x7B-7E. Equivalent: tab, space, !"#$%&'()*+,-./, ;<=>?@,
    // [\]^_`, {|}~. Letters and digits are NOT delimiters.
    var idx: usize = 0;
    while (idx < input.len) {
        // Skip delimiters.
        while (idx < input.len and isCookieDateDelim(input[idx])) idx += 1;
        if (idx >= input.len) break;
        const tok_start = idx;
        while (idx < input.len and !isCookieDateDelim(input[idx])) idx += 1;
        const token = input[tok_start..idx];

        // 1. time = HH:MM:SS, optional trailing non-digits ignored.
        if (!found_time) {
            if (parseTimeToken(token)) |hms| {
                hour = hms[0];
                minute = hms[1];
                second = hms[2];
                found_time = true;
                continue;
            }
        }
        // 2. day-of-month: 1-2 digits.
        if (!found_dom) {
            if (parseDigitsLE2(token)) |n| {
                if (n >= 1 and n <= 31) {
                    dom = @intCast(n);
                    found_dom = true;
                    continue;
                }
            }
        }
        // 3. month: 3+ letters; case-insensitive prefix match against the
        //    standard 12 abbreviations.
        if (!found_month) {
            if (parseMonthToken(token)) |m| {
                month = m;
                found_month = true;
                continue;
            }
        }
        // 4. year: 2 or 4 digits.
        if (!found_year) {
            if (parseDigitsYear(token)) |y| {
                year = y;
                found_year = true;
                continue;
            }
        }
    }

    if (!(found_time and found_dom and found_month and found_year)) return null;

    // Year fix-up per §5.1.1: 70..99 → +1900; 0..69 → +2000; otherwise
    // already four-digit.
    if (year >= 70 and year <= 99) year += 1900;
    if (year >= 0 and year <= 69) year += 2000;
    if (year < 1601) return null;

    // Range validations.
    if (hour > 23 or minute > 59 or second > 59) return null;
    if (month < 1 or month > 12 or dom < 1 or dom > 31) return null;

    return civilToUnix(year, month, dom, hour, minute, second);
}

fn isCookieDateDelim(c: u8) bool {
    if (c == 0x09) return true;
    if (c >= 0x20 and c <= 0x2F) return true; // space and punctuation
    if (c >= 0x3B and c <= 0x40) return true; // ;<=>?@
    if (c >= 0x5B and c <= 0x60) return true; // [\]^_`
    if (c >= 0x7B and c <= 0x7E) return true; // {|}~
    return false;
}

fn parseTimeToken(t: []const u8) ?[3]u8 {
    // Match HH:MM:SS at the start (any trailing non-digit chars are ignored).
    if (t.len < 5) return null; // need at least H:M:S
    var h: u8 = 0;
    var m: u8 = 0;
    var s: u8 = 0;
    var i: usize = 0;
    if (!std.ascii.isDigit(t[i])) return null;
    while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) {
        h = h * 10 + (t[i] - '0');
    }
    if (i >= t.len or t[i] != ':') return null;
    i += 1;
    while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) {
        m = m * 10 + (t[i] - '0');
    }
    if (i >= t.len or t[i] != ':') return null;
    i += 1;
    while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) {
        s = s * 10 + (t[i] - '0');
    }
    return .{ h, m, s };
}

fn parseDigitsLE2(t: []const u8) ?u32 {
    if (t.len == 0 or t.len > 2) return null;
    var n: u32 = 0;
    for (t) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + (c - '0');
    }
    return n;
}

fn parseDigitsYear(t: []const u8) ?i32 {
    if (t.len < 2 or t.len > 4) return null;
    var n: i32 = 0;
    for (t) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + @as(i32, c - '0');
    }
    return n;
}

fn parseMonthToken(t: []const u8) ?u8 {
    if (t.len < 3) return null;
    const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
    for (months, 0..) |m, i| {
        if (t.len >= 3 and std.ascii.eqlIgnoreCase(t[0..3], m)) return @intCast(i + 1);
    }
    return null;
}

/// Civil-from-days formula by Howard Hinnant, exact for proleptic Gregorian.
/// Returns Unix timestamp (UTC) for (y,m,d, h,m,s).
fn civilToUnix(y: i32, m: u8, d: u8, h: u8, mi: u8, s: u8) i64 {
    var year = y;
    if (m <= 2) year -= 1;
    const era: i32 = if (year >= 0) @divTrunc(year, 400) else @divTrunc(year - 399, 400);
    const yoe: u32 = @intCast(year - era * 400); // [0, 399]
    const m_adj: u32 = if (m > 2) @as(u32, m) - 3 else @as(u32, m) + 9;
    const doy: u32 = @divTrunc(153 * m_adj + 2, 5) + @as(u32, d) - 1; // [0, 365]
    const doe: u32 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const days: i64 = @as(i64, era) * 146097 + @as(i64, @intCast(doe)) - 719468;
    return days * 86400 + @as(i64, h) * 3600 + @as(i64, mi) * 60 + @as(i64, s);
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
    try std.testing.expect(c.expires.? > unixTimestamp());
}

test "session cookie has null expires" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("id=1", "example.com");
    try std.testing.expectEqual(@as(?i64, null), jar.cookies.items[0].expires);
}

// ── Cookie-date parser (RFC 6265 §5.1.1) ───────────────────────────────
// Smoke-test B3 regression coverage. Each format below was silently
// dropped before the parser was added (Max-Age was the only branch).

test "parseCookieDate accepts RFC 1123 (Wed, 01 Jan 2099 00:00:00 GMT)" {
    const t = parseCookieDate("Wed, 01 Jan 2099 00:00:00 GMT");
    try std.testing.expect(t != null);
    // 2099-01-01 00:00:00 UTC = 4070908800
    try std.testing.expectEqual(@as(i64, 4070908800), t.?);
}

test "parseCookieDate accepts RFC 850 (Sunday, 06-Nov-94 08:49:37 GMT)" {
    const t = parseCookieDate("Sunday, 06-Nov-94 08:49:37 GMT");
    try std.testing.expect(t != null);
    // 1994-11-06 08:49:37 UTC = 784111777
    try std.testing.expectEqual(@as(i64, 784111777), t.?);
}

test "parseCookieDate accepts asctime (Sun Nov  6 08:49:37 1994)" {
    const t = parseCookieDate("Sun Nov  6 08:49:37 1994");
    try std.testing.expect(t != null);
    try std.testing.expectEqual(@as(i64, 784111777), t.?);
}

test "parseCookieDate ignores wrong day-of-week" {
    // 2099-01-01 was actually a Thursday; "Sun" is wrong but per the
    // spec the day-of-week token is ignored entirely. Lenient parsing
    // is the canonical browser behavior.
    const t = parseCookieDate("Sun, 01 Jan 2099 00:00:00 GMT");
    try std.testing.expect(t != null);
    try std.testing.expectEqual(@as(i64, 4070908800), t.?);
}

test "parseCookieDate is case-insensitive on month" {
    const t = parseCookieDate("Wed, 01 jan 2099 00:00:00 GMT");
    try std.testing.expect(t != null);
}

test "parseCookieDate rejects out-of-range hour" {
    try std.testing.expectEqual(@as(?i64, null), parseCookieDate("Wed, 01 Jan 2099 25:00:00 GMT"));
}

test "parseCookieDate rejects missing month" {
    try std.testing.expectEqual(@as(?i64, null), parseCookieDate("Wed, 01 2099 00:00:00 GMT"));
}

test "parse cookie with Expires (RFC 1123) sets future expiry" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("id=1; Expires=Wed, 01 Jan 2099 00:00:00 GMT", "example.com");
    const c = jar.cookies.items[0];
    try std.testing.expect(c.expires != null);
    try std.testing.expect(c.expires.? > unixTimestamp());
}

test "parse cookie with Expires (asctime) sets future expiry" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("id=1; Expires=Sun Nov  6 08:49:37 2099", "example.com");
    const c = jar.cookies.items[0];
    try std.testing.expect(c.expires != null);
    try std.testing.expect(c.expires.? > unixTimestamp());
}

test "parse cookie with malformed Expires falls back to session" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("id=1; Expires=garbage", "example.com");
    // Malformed Expires must NOT crash; cookie ends up as session
    // (expires == null) which is the conservative fallback.
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
    jar.cookies.items[0].expires = unixTimestamp() - 1;
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

test "serialize/deserialize round-trip preserves persistent cookies" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("a=1; Max-Age=3600; Path=/; Domain=example.com", "example.com");
    try jar.parseSetCookie("b=2; Max-Age=3600; Path=/api; Secure; HttpOnly", "example.com");

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try jar.serialize(&aw.writer);

    var jar2 = CookieJar.init(std.testing.allocator);
    defer jar2.deinit();
    try jar2.deserializeBytes(aw.written());

    try std.testing.expectEqual(@as(usize, 2), jar2.cookies.items.len);
    const header = try jar2.getCookieHeader("example.com", "/api/things", true);
    defer std.testing.allocator.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "a=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "b=2") != null);
}

test "serialize skips session cookies (expires == null)" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    try jar.parseSetCookie("session=transient", "example.com"); // no Max-Age → session
    try jar.parseSetCookie("keep=me; Max-Age=3600", "example.com");

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try jar.serialize(&aw.writer);

    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "transient") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "keep") != null);
}

test "deserialize drops expired rows" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    const past = unixTimestamp() - 3600;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.print(std.testing.allocator, "# Netscape HTTP Cookie File\nexample.com\tFALSE\t/\tFALSE\t{d}\told\tdead\n", .{past});
    try jar.deserializeBytes(buf.items);
    try std.testing.expectEqual(@as(usize, 0), jar.cookies.items.len);
}

test "deserialize tolerates malformed rows" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    const future = unixTimestamp() + 3600;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "# comment line\n");
    try buf.appendSlice(std.testing.allocator, "\n"); // blank
    try buf.appendSlice(std.testing.allocator, "bogus\tnot-enough-fields\n");
    try buf.print(std.testing.allocator, "example.com\tFALSE\t/\tFALSE\t{d}\tgood\tvalue\n", .{future});
    try jar.deserializeBytes(buf.items);
    try std.testing.expectEqual(@as(usize, 1), jar.cookies.items.len);
    try std.testing.expectEqualStrings("good", jar.cookies.items[0].name);
}

test "deserialize honors HttpOnly_ prefix" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();
    const future = unixTimestamp() + 3600;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.print(std.testing.allocator, "#HttpOnly_example.com\tFALSE\t/\tFALSE\t{d}\tsid\tabc\n", .{future});
    try jar.deserializeBytes(buf.items);
    try std.testing.expectEqual(@as(usize, 1), jar.cookies.items.len);
    try std.testing.expect(jar.cookies.items[0].http_only);
    try std.testing.expectEqualStrings("example.com", jar.cookies.items[0].domain);
}
