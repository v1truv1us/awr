/// tls_fail_cache_path.zig — Resolve the on-disk path for the
/// `std_tls_failed_hosts` cache.
///
/// Without persistence, every CLI invocation pays the doomed
/// `fetchOnceStd` attempt cost (~100-160ms) the first time it visits a
/// JA4-fingerprint-sensitive host. Persisting the failure list lets
/// subsequent invocations skip the doomed attempt and go straight to
/// the BoringSSL fallback path.
///
/// Resolution order (first non-empty wins):
///   1. `$AWR_TLS_FAIL_CACHE` — explicit override
///   2. `$XDG_CACHE_HOME/awr/std_tls_fail_hosts.txt` — XDG cache dir
///   3. `$HOME/.cache/awr/std_tls_fail_hosts.txt` — XDG default
///
/// Returns `null` when none of the env vars resolves a usable path.
/// Caller owns the returned slice. The parent directory is created if
/// missing; the file itself is created lazily by Client when it has
/// failures to record.
///
/// This is an *auto-activating* cache (not opt-in like cookies):
/// hostnames-where-fingerprint-required is not user-private data, and
/// the only effect is faster cold-start. Agents that want a hermetic
/// run can set `AWR_TLS_FAIL_CACHE=/dev/null` or unset the resolver
/// envs.
const std = @import("std");

pub fn resolveTlsFailCachePath(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    if (try readEnv(allocator, "AWR_TLS_FAIL_CACHE")) |explicit| {
        try ensureParentDir(io, explicit);
        return explicit;
    }

    if (try readEnv(allocator, "XDG_CACHE_HOME")) |xdg_cache_home| {
        defer allocator.free(xdg_cache_home);
        const path = try std.fs.path.join(allocator, &.{ xdg_cache_home, "awr", "std_tls_fail_hosts.txt" });
        try ensureParentDir(io, path);
        return path;
    }

    if (try readEnv(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const path = try std.fs.path.join(allocator, &.{ home, ".cache", "awr", "std_tls_fail_hosts.txt" });
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
    try std.Io.Dir.cwd().createDirPath(io, parent);
}
