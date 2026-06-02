/// Raw terminal I/O for the TUI browser surface.
///
/// Owns the termios switch into raw mode, fullscreen alt-screen control,
/// terminal size queries, and the key/escape-sequence reader. The escape
/// parser is split into a pure `parseKeyFrom` helper (generic over a byte
/// source) so it can be unit-tested headlessly without a real TTY — see the
/// co-located tests at the bottom of this file. This matters because a real
/// terminal answers startup queries (Device Attributes, cursor position,
/// bracketed paste) that a headless PTY never sends; the parser must fully
/// consume those CSI sequences instead of leaking their trailing bytes (e.g.
/// the `c` that terminates a DA1 reply) as stray keystrokes.
const std = @import("std");

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

pub const Key = union(enum) {
    char: u8,
    enter,
    backspace,
    escape,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    tab,
    shift_tab,
    /// Ctrl+C / Ctrl+D — raw-mode quit signal. The TUI disables ISIG so the
    /// kernel does not deliver SIGINT; the run loop must treat this key as a
    /// universal exit so the terminal is always restored cleanly.
    interrupt,
};

pub const Size = struct {
    rows: usize,
    cols: usize,
};

pub const Terminal = struct {
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
    stdout_buffer: [4096]u8 = undefined,
    original_termios: c.struct_termios,
    raw_enabled: bool,

    pub fn init() !Terminal {
        const stdin_file = std.Io.File.stdin();
        const stdout_file = std.Io.File.stdout();

        var termios: c.struct_termios = undefined;
        if (c.tcgetattr(stdin_file.handle, &termios) != 0) return error.TermiosUnavailable;

        var raw = termios;
        const input_mask: c.tcflag_t = c.BRKINT | c.ICRNL | c.INPCK | c.ISTRIP | c.IXON;
        const output_mask: c.tcflag_t = c.OPOST;
        const local_mask: c.tcflag_t = c.ECHO | c.ICANON | c.IEXTEN | c.ISIG;
        raw.c_iflag &= ~input_mask;
        raw.c_oflag &= ~output_mask;
        raw.c_cflag |= @as(c.tcflag_t, c.CS8);
        raw.c_lflag &= ~local_mask;
        raw.c_cc[c.VMIN] = 1;
        raw.c_cc[c.VTIME] = 0;

        if (c.tcsetattr(stdin_file.handle, c.TCSAFLUSH, &raw) != 0) return error.TermiosUnavailable;

        // Discard any bytes already sitting in the TTY input buffer before the
        // key loop starts. A real terminal answers startup queries — most
        // notably the Sixel Device-Attributes probe (`ESC [ c`) that runs
        // before the TUI launches — and a fragmented or late DA reply can
        // leave residual bytes (including the trailing `c`) in the buffer. The
        // run loop would otherwise read that `c` as the open-cookie-inspector
        // keystroke. Flushing here is the primary, reliable guard; the escape
        // parser below is the belt-and-suspenders backstop.
        _ = c.tcflush(stdin_file.handle, c.TCIFLUSH);

        var terminal = Terminal{
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .original_termios = termios,
            .raw_enabled = true,
        };
        try terminal.enterFullscreen();
        return terminal;
    }

    pub fn deinit(self: *Terminal) void {
        self.leaveFullscreen() catch {};
        if (self.raw_enabled) {
            _ = c.tcsetattr(self.stdin_file.handle, c.TCSAFLUSH, &self.original_termios);
        }
    }

    pub fn size(self: *const Terminal) Size {
        var ws: c.struct_winsize = undefined;
        if (c.ioctl(self.stdout_file.handle, c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
            return .{ .rows = ws.ws_row, .cols = ws.ws_col };
        }
        return .{ .rows = 24, .cols = 80 };
    }

    pub fn enterFullscreen(self: *Terminal) !void {
        _ = self;
        std.debug.print("\x1b[?1049h\x1b[?25l", .{});
    }

    pub fn leaveFullscreen(self: *Terminal) !void {
        _ = self;
        std.debug.print("\x1b[?25h\x1b[?1049l", .{});
    }

    pub fn clearScreen(self: *Terminal) !void {
        _ = self;
        std.debug.print("\x1b[H\x1b[2J", .{});
    }

    pub fn readKey(self: *Terminal) !Key {
        return (try self.readKeyTimeout(-1)) orelse error.EndOfStream;
    }

    /// Wait up to `timeout_ms` for a key. Returns null on timeout. Pass -1 to
    /// block indefinitely (matches readKey). The run loop uses a finite timeout
    /// so it can re-check terminal size between user keystrokes — without this
    /// path SIGWINCH-equivalent resize events (iOS↔SSH↔tmux) are invisible to
    /// the renderer until the next keystroke arrives.
    pub fn readKeyTimeout(self: *Terminal, timeout_ms: i32) !?Key {
        return parseKeyFrom(self, timeout_ms);
    }

    fn readByte(self: *Terminal) !u8 {
        var buf: [1]u8 = undefined;
        const n = std.posix.system.read(self.stdin_file.handle, &buf, 1);
        if (n != 1) return error.EndOfStream;
        return buf[0];
    }

    fn readByteWithTimeout(self: *Terminal, timeout_ms: i32) !?u8 {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.stdin_file.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&fds, timeout_ms);
        if (ready == 0) return null;
        return try self.readByte();
    }
};

/// Decode one key from `source`, which must expose
/// `readByteWithTimeout(i32) !?u8`. Generic over the source so the escape
/// parser is testable without a real TTY (the tests pass a byte-slice fake).
///
/// `timeout_ms` bounds only the *first* byte; continuation bytes of an escape
/// sequence use a short fixed window so a lone `ESC` keypress still resolves
/// to `.escape`. Returns null when the first byte times out.
///
/// CSI handling is the load-bearing part: a full `ESC [ <params> <final>`
/// sequence is consumed to its final byte (`0x40..=0x7e`) and mapped to a
/// non-char token. Only the cursor/navigation finals (`A`/`B`/`C`/`D`/`Z`)
/// produce arrow/shift-tab keys; every other sequence — including a Device
/// Attributes reply such as `ESC [ ? 6 2 ; 1 ; 6 c` — is fully drained and
/// reported as `.escape`, never leaking its terminator (here `c`) as a
/// `.char` keystroke.
fn parseKeyFrom(source: anytype, timeout_ms: i32) !?Key {
    const first = (try source.readByteWithTimeout(timeout_ms)) orelse return null;
    switch (first) {
        0x03, 0x04 => return .interrupt,
        '\r', '\n' => return .enter,
        0x7f, 0x08 => return .backspace,
        '\t' => return .tab,
        0x1b => {
            const second = (try source.readByteWithTimeout(25)) orelse return .escape;
            if (second != '[') return .escape;
            return try parseCsi(source);
        },
        else => return .{ .char = first },
    }
}

/// Consume the body of a CSI sequence after the leading `ESC [` has been read.
/// Reads intermediate/parameter bytes (`0x20..=0x3f`) until a final byte
/// (`0x40..=0x7e`) arrives, then maps the recognized cursor finals to keys and
/// everything else to `.escape`. A truncated sequence (timeout before a final
/// byte) also resolves to `.escape`. The key invariant: no byte of a CSI
/// sequence is ever returned as a `.char`.
fn parseCsi(source: anytype) !Key {
    var final: u8 = (try source.readByteWithTimeout(25)) orelse return .escape;
    // Skip parameter and intermediate bytes (digits, `;`, `?`, `<`, etc.).
    while (final >= 0x20 and final <= 0x3f) {
        final = (try source.readByteWithTimeout(25)) orelse return .escape;
    }
    return switch (final) {
        'A' => .arrow_up,
        'B' => .arrow_down,
        'C' => .arrow_right,
        'D' => .arrow_left,
        'Z' => .shift_tab,
        else => .escape,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

/// Headless byte source for the escape parser. Replays a fixed slice one
/// byte per `readByteWithTimeout` call, returning null (timeout) once the
/// slice is drained — mirroring how a real TTY runs dry mid-sequence.
const FakeSource = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn readByteWithTimeout(self: *FakeSource, timeout_ms: i32) !?u8 {
        _ = timeout_ms;
        if (self.pos >= self.bytes.len) return null;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }
};

fn parseAll(allocator: std.mem.Allocator, bytes: []const u8) ![]Key {
    var src = FakeSource{ .bytes = bytes };
    var keys: std.ArrayList(Key) = .empty;
    errdefer keys.deinit(allocator);
    while (try parseKeyFrom(&src, 25)) |key| {
        try keys.append(allocator, key);
    }
    return keys.toOwnedSlice(allocator);
}

test "parseKeyFrom: DA reply is fully consumed, never yields char 'c'" {
    // This is the regression guard for the cookie-inspector-on-launch bug:
    // a real terminal's Device Attributes reply (ESC [ ? 6 2 ; 1 ; 6 c) used
    // to leak its trailing `c` into the key loop, which bound `c` to "open
    // cookie inspector". The whole sequence must collapse to a single,
    // non-char `.escape` token.
    const keys = try parseAll(testing.allocator, "\x1b[?62;1;6c");
    defer testing.allocator.free(keys);

    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expectEqual(Key.escape, keys[0]);
    for (keys) |k| {
        try testing.expect(k != .char);
    }
}

test "parseKeyFrom: plain 'c' still reaches the key loop as char 'c'" {
    // The fix must not swallow a genuine `c` keypress (cookie inspector
    // binding); only DA-style escape sequences are consumed.
    const keys = try parseAll(testing.allocator, "c");
    defer testing.allocator.free(keys);

    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expectEqual(Key{ .char = 'c' }, keys[0]);
}

test "parseKeyFrom: arrow keys and shift-tab still decode" {
    const keys = try parseAll(testing.allocator, "\x1b[A\x1b[B\x1b[C\x1b[D\x1b[Z");
    defer testing.allocator.free(keys);

    try testing.expectEqual(@as(usize, 5), keys.len);
    try testing.expectEqual(Key.arrow_up, keys[0]);
    try testing.expectEqual(Key.arrow_down, keys[1]);
    try testing.expectEqual(Key.arrow_right, keys[2]);
    try testing.expectEqual(Key.arrow_left, keys[3]);
    try testing.expectEqual(Key.shift_tab, keys[4]);
}

test "parseKeyFrom: DA reply followed by a real keystroke isolates the key" {
    // Even if a DA reply and a user keystroke arrive back to back, the `j`
    // (scroll-down) must survive as its own char and not be merged into or
    // shadowed by the escape sequence.
    const keys = try parseAll(testing.allocator, "\x1b[?62;1;6cj");
    defer testing.allocator.free(keys);

    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expectEqual(Key.escape, keys[0]);
    try testing.expectEqual(Key{ .char = 'j' }, keys[1]);
}

test "parseKeyFrom: lone ESC resolves to escape" {
    const keys = try parseAll(testing.allocator, "\x1b");
    defer testing.allocator.free(keys);

    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expectEqual(Key.escape, keys[0]);
}
