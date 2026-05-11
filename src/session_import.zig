/// session_import.zig — read cookies from Chrome / Firefox SQLite
/// stores and translate them into AWR's Cookie shape. T-85 / Tier 1
/// slice T1.9.
///
/// Strategy: shell out to the system `sqlite3` CLI rather than link
/// a compiled SQLite dependency. The browsers' cookie databases use
/// straightforward schemas; the bulk of the work is field-name and
/// time-base translation. Avoiding a vendored SQLite keeps the build
/// graph tight and matches the spec's "vendor or shell out" wording.
///
/// Locks: when the user's browser is running, the cookies DB is
/// held by it. We copy the source file to a `/tmp/...` location
/// first so the read can't contend.
///
/// Encryption: Chrome on macOS stores `value` empty and the real
/// value in `encrypted_value` (a BLOB) encrypted with a key in
/// Keychain. Decryption is deferred (spec §8.2). Cookies with empty
/// `value` and non-empty `encrypted_value` are skipped with a count
/// returned in the result so callers can surface "skipped N
/// encrypted cookies". Linux Chrome doesn't encrypt by default, so
/// imports from Linux Chrome work end-to-end.
const std = @import("std");

pub const Browser = enum { chrome, chromium, firefox };

/// Inline `wallClockMillis` — avoids importing `util/time.zig`
/// directly, which would collide with `page.zig`'s own import via
/// Zig's "same file from two module trees" rule.
fn wallClockMillis() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

pub const ImportError = error{
    Sqlite3Missing,
    SourceDbMissing,
    SourceDbCopyFailed,
    Sqlite3Failed,
    InvalidOutput,
};

pub const ImportedCookie = struct {
    host: []u8,
    name: []u8,
    value: []u8,
    path: []u8,
    expires: ?i64,
    secure: bool,
    http_only: bool,

    pub fn deinit(self: *ImportedCookie, alloc: std.mem.Allocator) void {
        alloc.free(self.host);
        alloc.free(self.name);
        alloc.free(self.value);
        alloc.free(self.path);
    }
};

pub const ImportResult = struct {
    cookies: []ImportedCookie,
    skipped_encrypted: usize,
    /// Caller frees: each cookie's owned strings + the outer slice.
    pub fn deinit(self: *ImportResult, alloc: std.mem.Allocator) void {
        for (self.cookies) |*c| c.deinit(alloc);
        alloc.free(self.cookies);
    }
};

/// Resolve the default cookies-DB path for the requested browser on
/// the current OS. Returns owned slice. Caller frees.
pub fn defaultPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    browser: Browser,
    profile_override: ?[]const u8,
) ![]u8 {
    const home_z = std.c.getenv("HOME") orelse return ImportError.SourceDbMissing;
    const home = std.mem.span(home_z);

    const is_macos = @import("builtin").target.os.tag == .macos;

    switch (browser) {
        .chrome => {
            if (is_macos) {
                return std.fmt.allocPrint(allocator, "{s}/Library/Application Support/Google/Chrome/Default/Cookies", .{home});
            }
            // Linux: ~/.config/google-chrome/Default/Cookies
            return std.fmt.allocPrint(allocator, "{s}/.config/google-chrome/Default/Cookies", .{home});
        },
        .chromium => {
            if (is_macos) {
                return std.fmt.allocPrint(allocator, "{s}/Library/Application Support/Chromium/Default/Cookies", .{home});
            }
            return std.fmt.allocPrint(allocator, "{s}/.config/chromium/Default/Cookies", .{home});
        },
        .firefox => {
            // Firefox stores profiles under a randomized directory name.
            // Resolve by reading profiles.ini OR scanning the dir for a
            // `*.default-release` (or override) match.
            const profiles_base: []u8 = if (is_macos)
                try std.fmt.allocPrint(allocator, "{s}/Library/Application Support/Firefox/Profiles", .{home})
            else
                try std.fmt.allocPrint(allocator, "{s}/.mozilla/firefox", .{home});
            defer allocator.free(profiles_base);

            const want_suffix: []const u8 = if (profile_override) |p| p else "default-release";
            const found = try findFirefoxProfile(allocator, io, profiles_base, want_suffix);
            defer allocator.free(found);

            return std.fmt.allocPrint(allocator, "{s}/{s}/cookies.sqlite", .{ profiles_base, found });
        },
    }
}

/// Scan a Firefox profiles directory for the first entry whose name
/// ends with `.${want_suffix}` (e.g. `abc123.default-release`).
/// Falls back to the first profile directory found when no match
/// matches the suffix. Uses `std.fs` (synchronous) — this runs once
/// at startup, no need for the async std.Io machinery.
fn findFirefoxProfile(
    allocator: std.mem.Allocator,
    io: std.Io,
    profiles_base: []const u8,
    want_suffix: []const u8,
) ![]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, profiles_base, .{ .iterate = true }) catch return ImportError.SourceDbMissing;
    defer dir.close(io);
    var it = dir.iterate();
    var first_dir: ?[]u8 = null;
    errdefer if (first_dir) |f| allocator.free(f);

    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.endsWith(u8, entry.name, want_suffix)) {
            if (first_dir) |f| allocator.free(f);
            return try allocator.dupe(u8, entry.name);
        }
        if (first_dir == null) first_dir = try allocator.dupe(u8, entry.name);
    }
    return first_dir orelse return ImportError.SourceDbMissing;
}

/// Read cookies from `source_path` and return an ImportResult.
/// Caller owns the result; call `result.deinit(allocator)` to free.
pub fn importFromDb(
    allocator: std.mem.Allocator,
    io: std.Io,
    browser: Browser,
    source_path: []const u8,
) !ImportResult {
    // Copy source to a temp file so the active browser doesn't
    // block our read. macOS and Linux both have /tmp.
    const pid = std.posix.system.getpid();
    const ts = wallClockMillis();
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/awr-import-{d}-{d}.sqlite", .{ pid, ts });
    defer {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        allocator.free(tmp_path);
    }

    try copyFile(io, source_path, tmp_path);

    // sqlite3 query: emit one JSON array of rows. Field names match
    // the browser-specific schema; the parser dispatches on `browser`.
    const query: []const u8 = switch (browser) {
        .firefox => "SELECT host, path, isSecure, isHttpOnly, expiry, name, value FROM moz_cookies;",
        .chrome, .chromium => "SELECT host_key AS host, path, is_secure AS isSecure, is_httponly AS isHttpOnly, expires_utc AS expiry, name, value, length(encrypted_value) AS enc_len FROM cookies;",
    };

    // Run sqlite3 in JSON mode. -readonly so we never write to the
    // temp DB. -cmd ".mode json" emits a single JSON array.
    const argv = [_][]const u8{
        "sqlite3",
        "-readonly",
        "-cmd",
        ".mode json",
        tmp_path,
        query,
    };

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return ImportError.Sqlite3Missing;

    const stdout_bytes = try drainPipe(io, allocator, &child.stdout.?);
    defer allocator.free(stdout_bytes);
    const stderr_bytes = try drainPipe(io, allocator, &child.stderr.?);
    defer allocator.free(stderr_bytes);

    const term = try child.wait(io);
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return ImportError.Sqlite3Failed;

    return parseSqliteJson(allocator, stdout_bytes, browser);
}

/// Read all bytes from a child's pipe into an owned slice. Mirrors
/// the pattern in `tests/integration_runner.zig:drainPipe`.
fn drainPipe(io: std.Io, allocator: std.mem.Allocator, file: *std.Io.File) ![]u8 {
    var buf: [16 * 1024]u8 = undefined;
    var r = file.reader(io, &buf);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    _ = r.interface.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => {},
        else => |e| return e,
    };
    return try aw.toOwnedSlice();
}

/// Copy `src` to `dst` byte-for-byte. Used to snapshot the browser's
/// locked cookies DB before reading.
fn copyFile(io: std.Io, src: []const u8, dst: []const u8) !void {
    const src_bytes = std.Io.Dir.cwd().readFileAlloc(io, src, std.heap.page_allocator, .limited(256 * 1024 * 1024)) catch return ImportError.SourceDbCopyFailed;
    defer std.heap.page_allocator.free(src_bytes);

    var out = std.Io.Dir.cwd().createFile(io, dst, .{}) catch return ImportError.SourceDbCopyFailed;
    defer out.close(io);
    var write_buf: [4096]u8 = undefined;
    var w = out.writer(io, &write_buf);
    w.interface.writeAll(src_bytes) catch return ImportError.SourceDbCopyFailed;
    w.interface.flush() catch return ImportError.SourceDbCopyFailed;
}

/// Parse sqlite3's `.mode json` output into ImportedCookie rows.
/// Handles browser-specific field mapping (Chrome's WebKit time base,
/// the encrypted-value skip path).
fn parseSqliteJson(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
    browser: Browser,
) !ImportResult {
    // Empty result is valid: jar exists but holds no cookies. sqlite3
    // emits nothing (empty body) for no-rows queries in json mode.
    const trimmed = std.mem.trim(u8, json_bytes, " \t\r\n");
    if (trimmed.len == 0) {
        return .{ .cookies = &[_]ImportedCookie{}, .skipped_encrypted = 0 };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return ImportError.InvalidOutput;
    defer parsed.deinit();

    if (parsed.value != .array) return ImportError.InvalidOutput;
    const rows = parsed.value.array.items;

    var cookies: std.ArrayList(ImportedCookie) = .empty;
    errdefer {
        for (cookies.items) |*c| c.deinit(allocator);
        cookies.deinit(allocator);
    }
    var skipped: usize = 0;

    for (rows) |row| {
        if (row != .object) continue;
        const obj = row.object;

        // Common fields: host, path, name, value, isSecure, isHttpOnly, expiry.
        const host = stringField(obj, "host") orelse continue;
        const path = stringField(obj, "path") orelse "/";
        const name = stringField(obj, "name") orelse continue;
        const value_raw = stringField(obj, "value") orelse "";
        const is_secure = boolFromInt(obj.get("isSecure"));
        const is_http_only = boolFromInt(obj.get("isHttpOnly"));

        // Chrome stores encrypted values in a separate BLOB column.
        // When `value` is empty and enc_len > 0, the real value is
        // encrypted — we can't decrypt yet (T-85 follow-up).
        if (browser == .chrome or browser == .chromium) {
            if (value_raw.len == 0) {
                const enc_len = intField(obj.get("enc_len")) orelse 0;
                if (enc_len > 0) {
                    skipped += 1;
                    continue;
                }
            }
        }

        const expiry_raw = intField(obj.get("expiry")) orelse 0;
        // Time conversion. Firefox: unix seconds. Chrome: microseconds
        // since 1601-01-01 UTC (WebKit time). Both → unix seconds.
        const expiry: ?i64 = switch (browser) {
            .firefox => if (expiry_raw <= 0) null else expiry_raw,
            .chrome, .chromium => if (expiry_raw <= 0) null else webkitToUnix(expiry_raw),
        };

        const c: ImportedCookie = .{
            .host = try allocator.dupe(u8, host),
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value_raw),
            .path = try allocator.dupe(u8, path),
            .expires = expiry,
            .secure = is_secure,
            .http_only = is_http_only,
        };
        try cookies.append(allocator, c);
    }

    return .{
        .cookies = try cookies.toOwnedSlice(allocator),
        .skipped_encrypted = skipped,
    };
}

/// Read a string-valued JSON field, treating numbers as their
/// stringification (sqlite3 emits numeric columns as JSON numbers).
fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        else => null,
    };
}

/// Read an integer-valued JSON field. Returns null for missing or
/// non-numeric values. Accepts both JSON numbers and number_string
/// (sqlite3 emits large integers as strings to preserve precision).
fn intField(opt_v: ?std.json.Value) ?i64 {
    const v = opt_v orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Coerce a JSON integer 0/1 (sqlite3 BOOLEAN) into a Zig bool.
fn boolFromInt(opt_v: ?std.json.Value) bool {
    const v = opt_v orelse return false;
    return switch (v) {
        .integer => |i| i != 0,
        .bool => |b| b,
        .number_string => |s| !std.mem.eql(u8, s, "0"),
        else => false,
    };
}

/// Convert Chrome/WebKit microseconds-since-1601 to Unix seconds.
/// 11644473600 = seconds between 1601-01-01 UTC and 1970-01-01 UTC.
fn webkitToUnix(webkit_micros: i64) i64 {
    return @divTrunc(webkit_micros, 1_000_000) - 11644473600;
}

// ── Tests ──────────────────────────────────────────────────────────

test "webkitToUnix converts known values" {
    // Sentinel: WebKit time 13_000_000_000_000_000 (Oct 2012) → Unix 1351753200ish.
    // Match against a value we computed: 13_000_000_000_000_000 / 1e6 = 13_000_000_000.
    // 13_000_000_000 - 11_644_473_600 = 1_355_526_400 (Dec 15, 2012 UTC). Close enough sanity.
    try std.testing.expectEqual(@as(i64, 1_355_526_400), webkitToUnix(13_000_000_000_000_000));
    // Zero stays at the epoch difference (i.e., the 1601 epoch — long pre-Unix).
    try std.testing.expectEqual(@as(i64, -11_644_473_600), webkitToUnix(0));
}

test "parseSqliteJson handles empty input" {
    var result = try parseSqliteJson(std.testing.allocator, "", .firefox);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.cookies.len);
    try std.testing.expectEqual(@as(usize, 0), result.skipped_encrypted);
}

test "parseSqliteJson reads Firefox row" {
    const json =
        \\[{"host":"example.com","path":"/","isSecure":1,"isHttpOnly":0,"expiry":2000000000,"name":"session","value":"abc"}]
    ;
    var result = try parseSqliteJson(std.testing.allocator, json, .firefox);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.cookies.len);
    const c = result.cookies[0];
    try std.testing.expectEqualStrings("example.com", c.host);
    try std.testing.expectEqualStrings("session", c.name);
    try std.testing.expectEqualStrings("abc", c.value);
    try std.testing.expectEqualStrings("/", c.path);
    try std.testing.expect(c.secure);
    try std.testing.expect(!c.http_only);
    try std.testing.expectEqual(@as(?i64, 2_000_000_000), c.expires);
}

test "parseSqliteJson skips Chrome encrypted_value rows" {
    // A row where value is empty but encrypted_value has bytes is the
    // macOS Chrome case. We count it in skipped_encrypted, don't emit it.
    const json =
        \\[{"host":"x.com","path":"/","isSecure":1,"isHttpOnly":1,"expiry":13000000000000000,"name":"sid","value":"","enc_len":48}]
    ;
    var result = try parseSqliteJson(std.testing.allocator, json, .chrome);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.cookies.len);
    try std.testing.expectEqual(@as(usize, 1), result.skipped_encrypted);
}

test "parseSqliteJson reads Chrome unencrypted row and converts time" {
    const json =
        \\[{"host":"x.com","path":"/api","isSecure":0,"isHttpOnly":0,"expiry":13000000000000000,"name":"k","value":"v","enc_len":0}]
    ;
    var result = try parseSqliteJson(std.testing.allocator, json, .chrome);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.cookies.len);
    const c = result.cookies[0];
    try std.testing.expectEqualStrings("x.com", c.host);
    try std.testing.expectEqualStrings("v", c.value);
    try std.testing.expectEqual(@as(?i64, 1_355_526_400), c.expires);
}
