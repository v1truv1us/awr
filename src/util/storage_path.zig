/// storage_path.zig — Resolve the on-disk directory for AWR's Web Storage
/// (localStorage) per-origin JSON files.
///
/// Resolution order (first non-empty wins):
///   1. `$AWR_STORAGE_DIR` — explicit override (used in tests)
///   2. `$XDG_DATA_HOME/awr/storage` — XDG Base Directory spec
///   3. `$HOME/.local/share/awr/storage` — XDG default
///
/// localStorage is per-origin auth state and may contain tokens, so the
/// directory is created with the process umask default and individual
/// files chmod'd to `0600` after creation (see `LocalStorage.flush` in
/// src/js/storage.zig).
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

test "resolveStorageDir — honors AWR_STORAGE_DIR override" {
    if (!@hasDecl(std.c, "setenv")) return error.SkipZigTest;
    const a = std.testing.allocator;

    // tmpDir gives a sub-path under .zig-cache/tmp/<sub>.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    defer a.free(dir_path);

    _ = std.c.setenv("AWR_STORAGE_DIR", dir_path.ptr, 1);
    defer _ = std.c.unsetenv("AWR_STORAGE_DIR");

    const resolved = (try resolveStorageDir(a, std.testing.io)).?;
    defer a.free(resolved);
    try std.testing.expectEqualStrings(dir_path[0..dir_path.len], resolved);
}
