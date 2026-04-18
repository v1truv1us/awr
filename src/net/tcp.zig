/// tcp.zig — TCP connection state machine (libxev async backend).
///
/// Phase 1: Each operation (connect / write / read) submits a single
/// completion to the kqueue/io_uring event loop and blocks the calling
/// thread with loop.run(.until_done).  This preserves the synchronous
/// call-site ergonomics of the old std.net implementation while routing
/// all socket I/O through libxev, laying the groundwork for full async
/// in Phase 2.
///
/// TODO(libxev-phase2): Replace loop.run(.until_done) with a shared
///   xev.Loop driven by the top-level AWR runtime.  Each operation will
///   become a Completion queued onto that loop, and callbacks will drive
///   state transitions instead of blocking.
///
/// State machine (unchanged from Phase 0):
///   idle → connecting  (connect() called)
///   connecting → connected  (handshake complete)
///   connected → draining  (close() called)
///   draining → closed  (FIN sent)
///   connecting → closed  (refused / timeout)
///   connected → closed  (error / remote RST)
const std   = @import("std");
const posix = std.posix;
const xev   = @import("xev");

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

// ── Internal callback context types ──────────────────────────────────────

/// Used by the connect callback to report success/failure.
const ConnCtx = struct { err: ?anyerror = null };

/// Used by read/write callbacks to report byte count or error.
const IoCtx = struct { result: anyerror!usize = 0 };

// ── TcpConn ───────────────────────────────────────────────────────────────

/// Async TCP connection backed by libxev.
///
/// The `loop` field is a per-connection event loop.  Phase 2 will replace
/// this with a pointer to a shared runtime loop.
pub const TcpConn = struct {
    loop:        xev.Loop,
    socket:      ?xev.TCP,
    state:       TcpState,
    remote_addr: std.Io.net.IpAddress,

    /// Read / write scratch buffers (arena-allocated per connection).
    read_buf:  []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,

    const READ_BUF_SIZE  = 64 * 1024;
    const WRITE_BUF_SIZE = 64 * 1024;

    pub fn init(allocator: std.mem.Allocator, remote_addr: std.Io.net.IpAddress) !TcpConn {
        const read_buf  = try allocator.alloc(u8, READ_BUF_SIZE);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, WRITE_BUF_SIZE);
        errdefer allocator.free(write_buf);
        const loop = try xev.Loop.init(.{});
        return TcpConn{
            .loop        = loop,
            .socket      = null,
            .state       = .idle,
            .remote_addr = remote_addr,
            .read_buf    = read_buf,
            .write_buf   = write_buf,
            .allocator   = allocator,
        };
    }

    pub fn deinit(self: *TcpConn) void {
        if (self.socket) |s| posix.close(s.fd);
        self.socket = null;
        self.loop.deinit();
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        self.state = .closed;
    }

    /// Establish a TCP connection to `remote_addr` via libxev.
    /// TODO(libxev-phase2): Queue onto shared loop; return immediately; drive
    ///   via callback.
    pub fn connect(self: *TcpConn) !void {
        if (self.state != .idle) return TcpError.AlreadyConnected;
        self.state = .connecting;

        const sock = xev.TCP.init(self.remote_addr) catch {
            self.state = .closed;
            return TcpError.ConnectionRefused;
        };

        var c: xev.Completion = undefined;
        var ctx = ConnCtx{};
        sock.connect(&self.loop, &c, self.remote_addr, ConnCtx, &ctx, connectCb);
        self.loop.run(.until_done) catch {
            self.state = .closed;
            posix.close(sock.fd);
            return TcpError.ConnectionRefused;
        };
        if (ctx.err != null) {
            self.state = .closed;
            posix.close(sock.fd);
            return TcpError.ConnectionRefused;
        }

        self.socket = sock;
        self.state  = .connected;
    }

    /// Write `data` to the connection. Returns bytes written.
    /// TODO(libxev-phase2): Queue onto shared loop; return via callback.
    pub fn write(self: *TcpConn, data: []const u8) !usize {
        if (self.state != .connected) return TcpError.NotConnected;

        var c: xev.Completion = undefined;
        var ctx = IoCtx{};
        self.socket.?.write(&self.loop, &c, .{ .slice = data },
                             IoCtx, &ctx, writeCb);
        self.loop.run(.until_done) catch return TcpError.WriteFailed;
        return ctx.result catch TcpError.WriteFailed;
    }

    /// Read into `buf`. Returns bytes read.
    /// TODO(libxev-phase2): Queue onto shared loop; return via callback.
    pub fn read(self: *TcpConn, buf: []u8) !usize {
        if (self.state != .connected) return TcpError.NotConnected;

        var c: xev.Completion = undefined;
        var ctx = IoCtx{};
        self.socket.?.read(&self.loop, &c, .{ .slice = buf },
                            IoCtx, &ctx, readCb);
        self.loop.run(.until_done) catch return TcpError.ReadFailed;
        return ctx.result catch TcpError.ReadFailed;
    }

    /// Initiate graceful close (drain writes, send FIN).
    /// TODO(libxev-phase2): Queue async shutdown completion.
    pub fn close(self: *TcpConn) void {
        if (self.state == .closed) return;
        self.state = .draining;
        if (self.socket) |s| {
            posix.close(s.fd);
            self.socket = null;
        }
        self.state = .closed;
    }

    /// std.io.GenericReader adapter — lets callers wrap TcpConn in a Reader
    /// (e.g. for http1.readResponse).
    ///
    /// Usage:
    ///   const R = std.io.GenericReader(*TcpConn, TcpError, TcpConn.readFn);
    ///   const reader = R{ .context = &conn };
    pub fn readFn(self: *TcpConn, buf: []u8) TcpError!usize {
        return self.read(buf);
    }
};

// ── libxev callbacks ──────────────────────────────────────────────────────

fn connectCb(
    ctx: ?*ConnCtx,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    r: xev.ConnectError!void,
) xev.CallbackAction {
    r catch |e| { ctx.?.err = e; };
    return .disarm;
}

fn writeCb(
    ctx: ?*IoCtx,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    ctx.?.result = r;
    return .disarm;
}

fn readCb(
    ctx: ?*IoCtx,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    ctx.?.result = r;
    return .disarm;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "TcpConn.init starts in idle state" {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 9999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();
    try std.testing.expectEqual(TcpState.idle, conn.state);
}

test "TcpConn.init allocates read and write buffers" {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 9999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();
    try std.testing.expectEqual(@as(usize, 64 * 1024), conn.read_buf.len);
    try std.testing.expectEqual(@as(usize, 64 * 1024), conn.write_buf.len);
}

test "TcpConn.write returns NotConnected when idle" {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 9999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();
    const result = conn.write("hello");
    try std.testing.expectError(TcpError.NotConnected, result);
}

test "TcpConn.read returns NotConnected when idle" {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 9999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();
    var buf: [64]u8 = undefined;
    const result = conn.read(&buf);
    try std.testing.expectError(TcpError.NotConnected, result);
}

test "TcpConn.connect returns ConnectionRefused for closed port" {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 19999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();
    const result = conn.connect();
    try std.testing.expectError(TcpError.ConnectionRefused, result);
    try std.testing.expectEqual(TcpState.closed, conn.state);
}

test "TcpConn.close transitions to closed state" {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 9999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();
    conn.close();
    try std.testing.expectEqual(TcpState.closed, conn.state);
}

test "TcpConn.close is idempotent" {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 9999);
    var conn = try TcpConn.init(std.testing.allocator, addr);
    defer conn.deinit();
    conn.close();
    conn.close();
    try std.testing.expectEqual(TcpState.closed, conn.state);
}

// Real TCP roundtrip via local echo server — now driven by libxev loop.
// TODO(libxev-phase2): Replace thread + loop.run(.until_done) with a
//   single shared xev.Loop running both sides concurrently.
test "TcpConn connect + write + read roundtrip via local echo server" {
    const port: u16 = 18472;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);

    const ServerCtx = struct {
        addr: std.Io.net.IpAddress,
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
