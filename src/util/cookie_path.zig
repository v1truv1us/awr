/// cookie_path.zig — Resolve the on-disk path for AWR's persistent cookie jar.
///
/// Resolution order (first non-empty wins):
///   1. `$AWR_COOKIE_JAR` — explicit override (agent-controlled)
///   2. `$XDG_STATE_HOME/awr/cookies.txt` — XDG Base Directory spec
///   3. `$HOME/.local/state/awr/cookies.txt` — XDG default location
///
/// Returns `null` when none of the env vars resolves a usable path. Caller owns
/// the returned slice. When a candidate path is returned, the parent directory
/// is created if missing (via `std.Io.Dir.cwd().createDirPath`). The file
/// itself is *not* created here — `Client` decides whether to write.
///
/// Activation is opt-in by env var presence per `spec/subspecs/agent-browser.md`
/// §2: AWR does not silently start persisting cookies for users who never
/// asked for it.
const std = @import("std");

/// Returns the resolved cookie-jar path (allocator-owned) or `null` if no env
/// var pointed us at one. Errors only on allocation failure or filesystem
/// issues creating the parent directory; absent env vars are not errors.
pub fn resolveCookieJarPath(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    if (try readEnv(allocator, "AWR_COOKIE_JAR")) |explicit| {
        try ensureParentDir(io, explicit);
        return explicit;
    }

    if (try readEnv(allocator, "XDG_STATE_HOME")) |xdg_state_home| {
        defer allocator.free(xdg_state_home);
        const path = try std.fs.path.join(allocator, &.{ xdg_state_home, "awr", "cookies.txt" });
        try ensureParentDir(io, path);
        return path;
    }

    if (try readEnv(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const path = try std.fs.path.join(allocator, &.{ home, ".local", "state", "awr", "cookies.txt" });
        try ensureParentDir(io, path);
        return path;
    }

    return null;
}

fn readEnv(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    if (!@hasDecl(std.c, "getenv")) return null;
    // libc requires a null-terminated name. Stack-allocate a small buffer to
    // avoid an allocator round-trip for short env-var names.
    var name_buf: [64]u8 = undefined;
    if (name.len + 1 > name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const raw = std.c.getenv(@ptrCast(&name_buf)) orelse return null;
    const span = std.mem.sliceTo(raw, 0);
    if (span.len == 0) return null;
    return try allocator.dupe(u8, span);
}

/// Create the parent directory of `path` (and intermediate directories) if
/// missing. `createDirPath` treats existing directories as success.
fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

// Tests for the env-var resolver are intentionally omitted: the file is not
// wired into any zig build addTest target and exercising it requires libc
// setenv plus filesystem side effects. The behavior is exercised end-to-end
// through Page integration paths instead.
