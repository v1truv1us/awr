/// dns.zig — host name resolution for AWR.
///
/// Zig 0.16 removed `std.net.getAddressList`. The new API is
/// `std.Io.net.HostName.lookup`, which is capability-gated on `Io`
/// and streams `LookupResult` values through an `Io.Queue`.
///
/// AWR's networking stack is synchronous from the caller's perspective
/// (libxev drives individual completions, but the HTTP client waits for
/// each). We therefore only need the first usable `IpAddress` for a
/// given host + port. `HostName.lookup` is documented to not block when
/// the provided queue has capacity ≥ 16, so we call it directly on the
/// calling thread without spinning up an `io.async` task.
///
/// The `resolve` helper tries a literal IP parse first (free for
/// `127.0.0.1`-style inputs in tests), then falls back to DNS.
const std = @import("std");
const IpAddress = std.Io.net.IpAddress;
const HostName = std.Io.net.HostName;

pub const ResolveError = error{
    InvalidHostName,
    DnsResolutionFailed,
} || HostName.LookupError;

/// Resolve `host` to a single `IpAddress` bound to `port`.
/// Prefers an IP literal if `host` parses as one, otherwise performs a
/// DNS lookup via `io` and returns the first address (IPv4 or IPv6).
pub fn resolve(io: std.Io, host: []const u8, port: u16) ResolveError!IpAddress {
    if (IpAddress.parse(host, port)) |addr| {
        return addr;
    } else |_| {}

    const host_name = HostName.init(host) catch return error.InvalidHostName;

    // Capacity ≥ 16 is required by HostName.lookup to guarantee
    // non-blocking behaviour when called synchronously.
    var buffer: [32]HostName.LookupResult = undefined;
    var queue: std.Io.Queue(HostName.LookupResult) = .init(&buffer);

    try host_name.lookup(io, &queue, .{ .port = port });

    while (queue.getOneUncancelable(io)) |result| {
        switch (result) {
            .address => |addr| return addr,
            .canonical_name => continue,
        }
    } else |err| switch (err) {
        error.Closed => return error.DnsResolutionFailed,
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "resolve returns literal IPv4 without DNS" {
    const addr = try resolve(std.testing.io, "127.0.0.1", 8080);
    try std.testing.expectEqual(@as(u16, 8080), addr.getPort());
}

test "resolve returns literal IPv6 without DNS" {
    const addr = try resolve(std.testing.io, "::1", 9000);
    try std.testing.expectEqual(@as(u16, 9000), addr.getPort());
}
