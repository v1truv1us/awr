/// bookmark_path.zig — Resolve the on-disk path for AWR's bookmarks store.
///
/// Resolution order (first non-empty wins):
///   1. `$AWR_BOOKMARKS` — explicit override
///   2. `$XDG_DATA_HOME/awr/bookmarks.txt` — XDG Base Directory spec
///   3. `$HOME/.local/share/awr/bookmarks.txt` — XDG default
///
/// Bookmarks (unlike cookies) are not opt-in — they're a user-initiated
/// action, so the path resolves unconditionally as long as `$HOME` or
/// `$XDG_DATA_HOME` is set. Mirrors `cookie_path.zig`'s shape. T-89.
const std = @import("std");

pub fn resolveBookmarksPath(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    if (try readEnv(allocator, "AWR_BOOKMARKS")) |explicit| {
        try ensureParentDir(io, explicit);
        return explicit;
    }

    if (try readEnv(allocator, "XDG_DATA_HOME")) |xdg| {
        defer allocator.free(xdg);
        const path = try std.fs.path.join(allocator, &.{ xdg, "awr", "bookmarks.txt" });
        try ensureParentDir(io, path);
        return path;
    }

    if (try readEnv(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const path = try std.fs.path.join(allocator, &.{ home, ".local", "share", "awr", "bookmarks.txt" });
        try ensureParentDir(io, path);
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

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    // Tolerate macOS's /tmp-symlink-to-/private/tmp case: createDirPath
    // can return NotDir when an existing symlinked component confuses
    // the stat walk. Both errors mean "parent is already there", which
    // is what we want.
    std.Io.Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
        error.PathAlreadyExists, error.NotDir => {},
        else => return err,
    };
}
