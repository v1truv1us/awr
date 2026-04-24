/// io.zig — small I/O adapters for AWR.
///
/// Zig 0.16 removed `std.io.GenericReader`. AWR's HTTP/1.1 parser
/// (`src/net/http1.zig`) is duck-typed via `reader: anytype` and only
/// uses two methods: `readUntilDelimiter(buf, delim) ![]u8` and
/// `readNoEof(dest) !void`. Rather than rewrite the parser around the
/// new `*std.Io.Reader` vtable, we provide a minimal blocking adapter
/// that wraps any context with a `read(buf) !usize`-shaped callback
/// and exposes just those two methods.
///
/// This is not a stdlib clone — it intentionally carries only what
/// AWR's synchronous TCP/TLS readers need. The underlying `readFn`
/// is expected to already block via the libxev loop or BoringSSL.
const std = @import("std");

pub const ReadError = error{
    EndOfStream,
    StreamTooLong,
} || anyerror;

/// Returns a reader adapter over `Context` that drives `readFn` until
/// the requested bytes are available. The adapter is zero-cost: it is
/// a comptime-generated struct with no heap state.
pub fn BlockingReader(
    comptime Context: type,
    comptime InnerError: type,
    comptime readFn: fn (context: Context, buf: []u8) InnerError!usize,
) type {
    return struct {
        context: Context,

        const Self = @This();
        pub const Error = InnerError || error{ EndOfStream, StreamTooLong };

        pub fn read(self: Self, dest: []u8) InnerError!usize {
            return readFn(self.context, dest);
        }

        /// Read up to one occurrence of `delim` into `buf`, returning
        /// the slice including the delimiter. Returns `StreamTooLong`
        /// if `buf` fills before `delim` is seen, and `EndOfStream`
        /// on a zero-byte read.
        pub fn readUntilDelimiter(self: Self, buf: []u8, delim: u8) Error![]u8 {
            var len: usize = 0;
            while (len < buf.len) {
                const n = try readFn(self.context, buf[len .. len + 1]);
                if (n == 0) return error.EndOfStream;
                len += n;
                if (buf[len - 1] == delim) return buf[0..len];
            }
            return error.StreamTooLong;
        }

        /// Fill `dest` completely. Returns `EndOfStream` if the stream
        /// closes before `dest.len` bytes have been read.
        pub fn readNoEof(self: Self, dest: []u8) Error!void {
            var filled: usize = 0;
            while (filled < dest.len) {
                const n = try readFn(self.context, dest[filled..]);
                if (n == 0) return error.EndOfStream;
                filled += n;
            }
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const TestStream = struct {
    data: []const u8,
    pos: usize = 0,

    fn read(self: *TestStream, buf: []u8) error{}!usize {
        const remaining = self.data[self.pos..];
        const n = @min(buf.len, remaining.len);
        @memcpy(buf[0..n], remaining[0..n]);
        self.pos += n;
        return n;
    }
};

test "BlockingReader.readUntilDelimiter returns slice including delimiter" {
    var stream = TestStream{ .data = "hello\nworld\n" };
    const R = BlockingReader(*TestStream, error{}, TestStream.read);
    const r = R{ .context = &stream };

    var buf: [16]u8 = undefined;
    const line = try r.readUntilDelimiter(&buf, '\n');
    try std.testing.expectEqualStrings("hello\n", line);
}

test "BlockingReader.readUntilDelimiter returns StreamTooLong when buffer fills" {
    var stream = TestStream{ .data = "no-newline-here" };
    const R = BlockingReader(*TestStream, error{}, TestStream.read);
    const r = R{ .context = &stream };

    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.StreamTooLong, r.readUntilDelimiter(&buf, '\n'));
}

test "BlockingReader.readNoEof fills buffer completely" {
    var stream = TestStream{ .data = "abcdefgh" };
    const R = BlockingReader(*TestStream, error{}, TestStream.read);
    const r = R{ .context = &stream };

    var buf: [5]u8 = undefined;
    try r.readNoEof(&buf);
    try std.testing.expectEqualStrings("abcde", &buf);
}

test "BlockingReader.readNoEof returns EndOfStream on short stream" {
    var stream = TestStream{ .data = "abc" };
    const R = BlockingReader(*TestStream, error{}, TestStream.read);
    const r = R{ .context = &stream };

    var buf: [5]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, r.readNoEof(&buf));
}
