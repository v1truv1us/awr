/// main_daemon.zig — `awrd` daemon entry point.
///
/// Implementation slice 1 (B3.2 minimal viable): listens on a Unix
/// domain socket, accepts connections sequentially, reads
/// Content-Length-framed JSON-RPC 2.0 requests via `jsonrpc.zig`, and
/// dispatches to a small in-process method table. v1 covers `ping`
/// (returns pong + version) and `shutdown` (graceful exit). `fetch`,
/// `tools`, `call` arrive in subsequent slices per
/// `spec/subspecs/daemon-mode.md §6`.
///
/// Sequential accept (no per-connection thread) is correct for v1 —
/// the spec calls for "one agent, one request at a time"; concurrent
/// requests are a future-work item gated on Page-instance isolation.
///
/// Socket path resolution per `spec/subspecs/daemon-mode.md §2.1`:
///   `${XDG_RUNTIME_DIR:-/tmp}/awrd-${UID}.sock`
const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const build_opts = @import("build_opts");

/// Maximum body bytes per request frame. 1 MiB is generous for v1
/// (typical fetch param JSON is well under 1 KB; even multi-redirect
/// responses are <100 KB). Enforced inside readFrame so the daemon
/// can't be DOSed by a peer that streams a huge Content-Length.
const MAX_BODY_BYTES: usize = 1 * 1024 * 1024;

/// Per-connection read/write buffer sizes. Frame headers sit under
/// MAX_HEADER_LINE (4 KiB) and bodies are bounded above; 16 KiB read
/// + 16 KiB write covers the steady state with one reallocation
/// budget for outsized frames.
const READ_BUFFER_BYTES: usize = 16 * 1024;
const WRITE_BUFFER_BYTES: usize = 16 * 1024;

pub fn run(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8) !void {
    // Pre-flight: remove any leftover socket file from a previous
    // crashed run. Spec §2.5's "double-fork + flock pid file" path
    // owns crash-survivor handling; for v1 we keep it simple.
    std.Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {}, // expected — first run
        else => return err,
    };

    const ua = try std.Io.net.UnixAddress.init(socket_path);
    var server = try ua.listen(io, .{});
    defer server.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};

    log("awrd: listening on {s} version=0.0.{s}", .{ socket_path, build_opts.git_hash });

    var should_exit = false;
    while (!should_exit) {
        var stream = server.accept(io) catch |err| {
            log("awrd: accept failed: {t}", .{err});
            continue;
        };
        defer stream.close(io);

        handleConnection(allocator, io, &stream, &should_exit) catch |err| {
            log("awrd: connection error: {t}", .{err});
        };
    }
    log("awrd: shutdown complete", .{});
}

fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    should_exit: *bool,
) !void {
    const read_buf = try allocator.alloc(u8, READ_BUFFER_BYTES);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, WRITE_BUFFER_BYTES);
    defer allocator.free(write_buf);

    var net_reader = stream.reader(io, read_buf);
    var net_writer = stream.writer(io, write_buf);

    // Adapt std.Io.Reader/Writer to the shape jsonrpc's anytype helpers
    // expect: readUntilDelimiter / readNoEof on the reader, print /
    // writeAll on the writer. Both shims hold a single pointer so they
    // are cheap and self-contained.
    var rshim: ReaderShim = .{ .src = &net_reader.interface };
    var wshim: WriterShim = .{ .dst = &net_writer.interface };

    const body = jsonrpc.readFrame(&rshim, allocator, MAX_BODY_BYTES) catch |err| {
        log("awrd: readFrame error: {t}", .{err});
        return;
    };
    defer allocator.free(body);

    var req = jsonrpc.parseRequest(allocator, body) catch |err| {
        log("awrd: parseRequest error: {t}", .{err});
        try jsonrpc.writeError(&wshim, allocator, "null", .parse_error, "invalid request");
        try net_writer.interface.flush();
        return;
    };
    defer req.deinit();

    const method = req.method() orelse "<missing>";
    const id_json = try jsonrpc.idToJson(allocator, req.id());
    defer allocator.free(id_json);

    if (std.mem.eql(u8, method, "ping")) {
        const result = try std.fmt.allocPrint(
            allocator,
            "{{\"value\":\"pong\",\"version\":\"0.0.{s}\"}}",
            .{build_opts.git_hash},
        );
        defer allocator.free(result);
        try jsonrpc.writeSuccess(&wshim, allocator, id_json, result);
    } else if (std.mem.eql(u8, method, "shutdown")) {
        try jsonrpc.writeSuccess(&wshim, allocator, id_json, "\"shutting down\"");
        should_exit.* = true;
    } else {
        try jsonrpc.writeError(&wshim, allocator, id_json, .method_not_found, method);
    }
    try net_writer.interface.flush();
}

// ── Reader/Writer shims for jsonrpc's anytype helpers ─────────────

const ReaderShim = struct {
    src: *std.Io.Reader,

    pub fn readUntilDelimiter(self: *ReaderShim, out: []u8, delim: u8) ![]u8 {
        // readSliceShort returns ReadFailed only — partial read is
        // signalled by n < dest.len (n=0 = EOF). We surface the EOF as
        // a partial slice (mid-line) or error.EndOfStream (start of
        // line) so jsonrpc.readFrame's framing-error branches stay
        // consistent with the http1.zig TestReader contract.
        var len: usize = 0;
        while (len < out.len) {
            var single: [1]u8 = undefined;
            const n = try self.src.readSliceShort(&single);
            if (n == 0) {
                if (len == 0) return error.EndOfStream;
                return out[0..len];
            }
            out[len] = single[0];
            len += 1;
            if (single[0] == delim) return out[0..len];
        }
        return error.StreamTooLong;
    }

    pub fn readNoEof(self: *ReaderShim, dest: []u8) !void {
        var filled: usize = 0;
        while (filled < dest.len) {
            const n = try self.src.readSliceShort(dest[filled..]);
            if (n == 0) return error.EndOfStream;
            filled += n;
        }
    }
};

const WriterShim = struct {
    dst: *std.Io.Writer,

    pub fn print(self: *WriterShim, comptime fmt: []const u8, args: anytype) !void {
        try self.dst.print(fmt, args);
    }

    pub fn writeAll(self: *WriterShim, bytes: []const u8) !void {
        try self.dst.writeAll(bytes);
    }
};

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// Resolve the daemon's socket path per spec §2.1.
/// `${XDG_RUNTIME_DIR:-/tmp}/awrd-${UID}.sock`.
/// Caller owns the returned slice.
pub fn resolveSocketPath(allocator: std.mem.Allocator) ![]u8 {
    const xdg_raw = std.c.getenv("XDG_RUNTIME_DIR");
    const dir: []const u8 = if (xdg_raw != null) blk: {
        const span = std.mem.sliceTo(xdg_raw.?, 0);
        if (span.len == 0) break :blk "/tmp";
        break :blk span;
    } else "/tmp";
    const uid = std.posix.system.geteuid();
    return std.fmt.allocPrint(allocator, "{s}/awrd-{d}.sock", .{ dir, uid });
}

// ── Entry point ────────────────────────────────────────────────────

pub fn main(minimal: std.process.Init.Minimal) !void {
    comptime {
        if (!@import("builtin").link_libc)
            @compileError("awrd must be built with link_libc — std.heap.c_allocator requires libc");
    }
    // c_allocator: matches main.zig's choice and steers clear of the
    // DebugAllocator stack-trace path that crashes pre-main on 0.16.
    const alloc = std.heap.c_allocator;

    var threaded: std.Io.Threaded = .init(alloc, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const socket_path = try resolveSocketPath(alloc);
    defer alloc.free(socket_path);

    try run(alloc, io, socket_path);
}

// ── Tests ──────────────────────────────────────────────────────────

test "resolveSocketPath honors XDG_RUNTIME_DIR or /tmp default" {
    const allocator = std.testing.allocator;
    const path = try resolveSocketPath(allocator);
    defer allocator.free(path);
    // Must end with `awrd-<uid>.sock` — the uid varies, so just check
    // the prefix and suffix.
    try std.testing.expect(std.mem.indexOf(u8, path, "/awrd-") != null);
    try std.testing.expect(std.mem.endsWith(u8, path, ".sock"));
}
