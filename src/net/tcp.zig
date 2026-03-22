/// tcp.zig — TCP connection state machine.
///
/// Phase 1 implementation uses synchronous std.net for correctness.
/// libxev (async I/O via io_uring/kqueue) will replace this in Phase 2.
///
/// All async-specific code is marked:
///   // TODO(libxev): replace with async xev.TCP equivalent
///
/// State machine:
///   idle → connecting  (connect() called)
///   connecting → connected  (TCP handshake complete)
///   connected → draining  (graceful close initiated)
///   draining → closed  (all writes flushed, FIN sent)
///   connecting → closed  (connection refused / timeout)
///   connected → closed  (error or remote RST)
const std = @import("std");

// ── Types ─────────────────────────────────────────────────────────────────

pub const TcpState = enum {
    idle,
    connecting,
    connected,
    draining,
    closed,
};

pub const TcpError = error{
    NotConnected,
    AlreadyConnected,
    AlreadyClosed,
    ConnectionRefused,
    Timeout,
    WriteFailed,
    ReadFailed,
};

// ── TcpConn ───────────────────────────────────────────────────────────────

/// TCP connection state machine.
///
/// TODO(libxev): Replace std.net.Stream with xev.TCP and xev.Loop.
///   The fields would become:
///     loop: *xev.Loop,
///     socket: xev.TCP,
///   and connect/write/read would take xev.Callback completion handlers.
pub const TcpConn = struct {
    /// Synchronous TCP stream (TODO(libxev): replace with xev.TCP)
    stream: ?std.net.Stream,

    state: TcpState,
    remote_addr: std.net.Address,

    /// Read/write buffers — arena-allocated per connection lifetime.
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,

    const READ_BUF_SIZE  = 64 * 1024; // 64 KB
    const WRITE_BUF_SIZE = 64 * 1024;

    pub fn init(allocator: std.mem.Allocator, remote_addr: std.net.Address) !TcpConn {
        const read_buf  = try allocator.alloc(u8, READ_BUF_SIZE);
        const write_buf = try allocator.alloc(u8, WRITE_BUF_SIZE);
        return TcpConn{
            .stream      = null,
            .state       = .idle,
            .remote_addr = remote_addr,
            .read_buf    = read_buf,
            .write_buf   = write_buf,
            .allocator   = allocator,
        };
    }

    pub fn deinit(self: *TcpConn) void {
        if (self.stream) |s| s.close();
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        self.state = .closed;
    }

    /// Establish a TCP connection to `remote_addr`.
    /// TODO(libxev): Replace with async xev.TCP.connect(loop, addr, callback).
    pub fn connect(self: *TcpConn) !void {
        if (self.state != .idle) return TcpError.AlreadyConnected;
        self.state = .connecting;
        self.stream = std.net.tcpConnectToAddress(self.remote_addr) catch |err| {
            self.state = .closed;
            return switch (err) {
                error.ConnectionRefused => TcpError.ConnectionRefused,
                else => TcpError.ConnectionRefused,
            };
        };
        self.state = .connected;
    }

    /// Write `data` to the connection. Returns number of bytes written.
    /// TODO(libxev): Replace with async xev.TCP.write(loop, data, callback).
    pub fn write(self: *TcpConn, data: []const u8) !usize {
        if (self.state != .connected) return TcpError.NotConnected;
        const n = self.stream.?.write(data) catch return TcpError.WriteFailed;
        return n;
    }

    /// Read into `buf`. Returns number of bytes read.
    /// TODO(libxev): Replace with async xev.TCP.read(loop, buf, callback).
    pub fn read(self: *TcpConn, buf: []u8) !usize {
        if (self.state != .connected) return TcpError.NotConnected;
        const n = self.stream.?.read(buf) catch return TcpError.ReadFailed;
        return n;
    }

    /// Initiate graceful close (drain writes, send FIN).
    /// TODO(libxev): Replace with xev.TCP.shutdown(loop, callback).
    pub fn close(self: *TcpConn) void {
        if (self.state == .closed) return;
        self.state = .draining;
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
        self.state = .closed;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "TcpConn.init starts in idle state" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 9999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();
    try std.testing.expectEqual(TcpState.idle, conn.state);
}

test "TcpConn.init allocates read and write buffers" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 9999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();
    try std.testing.expectEqual(@as(usize, 64 * 1024), conn.read_buf.len);
    try std.testing.expectEqual(@as(usize, 64 * 1024), conn.write_buf.len);
}

test "TcpConn.write returns NotConnected when idle" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 9999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();
    const result = conn.write("hello");
    try std.testing.expectError(TcpError.NotConnected, result);
}

test "TcpConn.read returns NotConnected when idle" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 9999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();
    var buf: [64]u8 = undefined;
    const result = conn.read(&buf);
    try std.testing.expectError(TcpError.NotConnected, result);
}

test "TcpConn.connect returns ConnectionRefused for closed port" {
    // Port 19999 should not be listening
    const addr = try std.net.Address.parseIp4("127.0.0.1", 19999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();
    const result = conn.connect();
    try std.testing.expectError(TcpError.ConnectionRefused, result);
    try std.testing.expectEqual(TcpState.closed, conn.state);
}

test "TcpConn.close transitions to closed state" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 9999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit(); // frees read_buf/write_buf regardless of state
    conn.close();
    try std.testing.expectEqual(TcpState.closed, conn.state);
}

test "TcpConn.close is idempotent" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 9999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();
    conn.close();
    conn.close(); // second call must not crash
    try std.testing.expectEqual(TcpState.closed, conn.state);
}

// Real TCP roundtrip test: spin up a local server in a thread, connect,
// write "ping", read it back (echo), verify.
// TODO(libxev): This test uses synchronous std.net. Replace thread with xev loop.
test "TcpConn connect + write + read roundtrip via local echo server" {
    // Pick an ephemeral port
    const port: u16 = 18472;
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);

    // Start a minimal echo server in a background thread
    const ServerCtx = struct {
        addr: std.net.Address,
        ready: std.Thread.Semaphore = .{},

        fn serve(ctx: *@This()) void {
            var server = ctx.addr.listen(.{ .reuse_address = true }) catch return;
            defer server.deinit();
            ctx.ready.post();
            const connection = server.accept() catch return;
            defer connection.stream.close();
            var echo_buf: [64]u8 = undefined;
            const n = connection.stream.read(&echo_buf) catch return;
            _ = connection.stream.write(echo_buf[0..n]) catch {};
        }
    };
    var ctx = ServerCtx{ .addr = addr };
    const thread = try std.Thread.spawn(.{}, ServerCtx.serve, .{&ctx});
    ctx.ready.wait();
    defer thread.join();

    // Client
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();

    try conn.connect();
    try std.testing.expectEqual(TcpState.connected, conn.state);

    const written = try conn.write("ping");
    try std.testing.expectEqual(@as(usize, 4), written);

    var recv_buf: [64]u8 = undefined;
    const received = try conn.read(&recv_buf);
    try std.testing.expectEqual(@as(usize, 4), received);
    try std.testing.expectEqualStrings("ping", recv_buf[0..received]);
}
