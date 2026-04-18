/// time.zig — wall-clock time helpers.
///
/// Zig 0.16 removed `std.time.timestamp()` / `std.time.milliTimestamp()`.
/// Absolute Unix time now requires either the `std.Io` capability (for
/// async-friendly access) or a direct POSIX `clock_gettime` syscall.
///
/// AWR's cookie jar and connection pool need monotonic-ish wall-clock
/// time for expiry/idle bookkeeping. Threading `Io` through those call
/// sites adds noise for a value that the OS can provide directly, so
/// this module wraps `posix.system.clock_gettime(.REALTIME, ...)` —
/// the same primitive `std.Io.Threaded` uses under the hood.
const std = @import("std");
const posix = std.posix;

/// Seconds since the Unix epoch. Matches the old `std.time.timestamp()`.
pub fn wallClockSeconds() i64 {
    var ts: posix.timespec = undefined;
    _ = posix.system.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

/// Milliseconds since the Unix epoch. Matches the old `std.time.milliTimestamp()`.
pub fn wallClockMillis() i64 {
    var ts: posix.timespec = undefined;
    _ = posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

test "wallClockSeconds returns positive value" {
    try std.testing.expect(wallClockSeconds() > 0);
}

test "wallClockMillis returns positive value and is roughly s*1000" {
    const s = wallClockSeconds();
    const ms = wallClockMillis();
    try std.testing.expect(ms > 0);
    // Within 2 seconds of each other (tolerates the gap between calls).
    const diff = ms - s * std.time.ms_per_s;
    try std.testing.expect(diff >= -2000 and diff <= 2000);
}
