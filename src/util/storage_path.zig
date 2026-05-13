/// storage_path.zig — Resolve the on-disk directory for AWR's Web Storage
/// (localStorage) per-origin JSON files.
///
/// Resolution order (first non-empty wins):
///   1. `$AWR_STORAGE_DIR` — explicit override (used in tests)
///   2. `$XDG_DATA_HOME/awr/storage` — XDG Base Directory spec
///   3. `$HOME/.local/share/awr/storage` — XDG default
///
/// localStorage is per-origin auth state and may contain tokens, so the
/// directory is created with `0700` and individual files with `0600`
/// (see `LocalStorage.flush` in src/js/storage.zig).
///
/// Mirrors `bookmark_path.zig`'s shape. Tier 3 — T3.A Web Storage.
const std = @import("std");

pub fn resolveStorageDir(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    if (try readEnv(allocator, "AWR_STORAGE_DIR")) |explicit| {
        try ensureDir(io, explicit);
        return explicit;
    }

    if (try readEnv(allocator, "XDG_DATA_HOME")) |xdg| {
        defer allocator.free(xdg);
        const path = try std.fs.path.join(allocator, &.{ xdg, "awr", "storage" });
        try ensureDir(io, path);
        return path;
    }

    if (try readEnv(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const path = try std.fs.path.join(allocator, &.{ home, ".local", "share", "awr", "storage" });
        try ensureDir(io, path);
        return path;
    }

    return null;
}

/// Encode an origin (e.g. `https://example.com:8080`) into a filesystem-safe
/// filename stem. Origins are produced by `Url.parse` so they're already
/// well-formed; we just replace separators that confuse the filesystem.
///
///   `https://example.com`        → `https__example.com`
///   `http://localhost:3000`      → `http__localhost_3000`
///   `https://例え.jp`            → `https__例え.jp` (UTF-8 passes through)
///
/// Caller owns the returned slice.
pub fn encodeOrigin(allocator: std.mem.Allocator, origin: []const u8) ![]u8 {
    // Conservative size: input length + a few chars for `://` → `__`.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, origin.len + 8);

    var i: usize = 0;
    while (i < origin.len) {
        if (i + 3 <= origin.len and std.mem.eql(u8, origin[i .. i + 3], "://")) {
            try out.appendSlice(allocator, "__");
            i += 3;
            continue;
        }
        const c = origin[i];
        switch (c) {
            // Replace anything that breaks paths or is too clever on filesystems.
            // `:` is a path separator on Windows; `/` and `\` on any OS.
            ':', '/', '\\' => try out.append(allocator, '_'),
            // Reject control chars / nulls outright — Url.parse should already
            // exclude these but be defensive.
            0...0x1f, 0x7f => return error.InvalidOrigin,
            else => try out.append(allocator, c),
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn readEnv(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    if (!@hasDecl(std.c, "getenv")) return null;
    var name_buf: [64]u8 = undefined;
    if (name.len + 1 > name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const raw = std.c.getenv(@ptrCast(&name_buf)) orelse return null;
    const span = std.mem.sliceTo(raw, 0);
    if (span.len == 0) return null;
    return try allocator.dupe(u8, span);
}

fn ensureDir(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists, error.NotDir => {},
        else => return err,
    };
}

test "encodeOrigin — https default port" {
    const a = std.testing.allocator;
    const out = try encodeOrigin(a, "https://example.com");
    defer a.free(out);
    try std.testing.expectEqualStrings("https__example.com", out);
}

test "encodeOrigin — http with explicit port" {
    const a = std.testing.allocator;
    const out = try encodeOrigin(a, "http://localhost:3000");
    defer a.free(out);
    try std.testing.expectEqualStrings("http__localhost_3000", out);
}

test "encodeOrigin — rejects control chars" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidOrigin, encodeOrigin(a, "https://example.com\x00"));
}

test "encodeOrigin — IPv6-style colons get replaced (filesystem-safe)" {
    const a = std.testing.allocator;
    const out = try encodeOrigin(a, "http://[::1]:8080");
    defer a.free(out);
    // Each `:` becomes `_` so the result is reversible by inspection only,
    // not algorithmically. Good enough for a per-origin cache filename.
    try std.testing.expectEqualStrings("http__[__1]_8080", out);
}
