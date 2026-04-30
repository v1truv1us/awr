/// Terminal-image protocol detection and dispatch policy.
///
/// Per `spec/subspecs/rendering.md §3.1`: AWR resolves the user's
/// `--images=auto|kitty|iterm|sixel|braille|none` choice into a concrete
/// protocol by combining (a) explicit user override, (b) environment
/// signals, (c) an optional Sixel CSI probe with a 50 ms timeout, and
/// (d) a hard non-TTY override that forces `.none` when stdout is
/// redirected — `awr render | tee` must stay grep-friendly (`§6` gate 8).
///
/// Design split:
///
///   • `resolve` is **pure**: no syscalls, no env access, no allocation.
///     Every branch is a deterministic unit test. The caller threads in
///     an `EnvSnapshot` and a `?probe_sixel` function pointer.
///
///   • `realEnvSnapshot`, `stdoutIsTty`, and `probeSixel` are the small
///     I/O helpers the runtime wires together once at startup. They are
///     not unit-tested directly; their inputs (env vars, fd state) are
///     part of the OS, not our logic.
///
///   • `da1HasSixel` parses a DA1 response (`ESC[?...c`) splitting on
///     `;` to find the literal parameter `4`. A naive
///     `indexOf "4"` would match `14` or `24` (which are unrelated
///     capabilities) and would silently emit Sixel bytes to a non-Sixel
///     terminal — a user-visible regression.
const std = @import("std");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
});

/// The actual protocol AWR will use to render a given image. `none`
/// means render the alt-text fallback only (no protocol bytes at all).
pub const Protocol = enum { kitty, iterm, sixel, braille, none };

/// What the user requested via `--images=...`. `auto` triggers env +
/// probe-based detection; the other variants are explicit overrides.
pub const Mode = enum { auto, kitty, iterm, sixel, braille, none };

/// Snapshot of the env vars `resolve` cares about. The runtime
/// populates this once via `realEnvSnapshot`; tests build it as a
/// literal. Strings are borrowed — caller owns lifetime.
pub const EnvSnapshot = struct {
    kitty_window_id: ?[]const u8 = null,
    term_program: ?[]const u8 = null,
    lc_terminal: ?[]const u8 = null,
};

/// Optional Sixel-capability probe. Called only when `mode == .auto` and
/// no env signal matched. Returning `false` (or omitting the probe)
/// causes `resolve` to fall through to braille — the safe default for
/// unknown terminals.
pub const ProbeSixelFn = *const fn () bool;

pub const ResolveOptions = struct {
    mode: Mode,
    stdout_is_tty: bool,
    env: EnvSnapshot = .{},
    probe_sixel: ?ProbeSixelFn = null,
};

/// Parse the value side of `--images=<value>`. Returns `null` for
/// unknown values so the caller can produce a useful error message.
pub fn parseMode(value: []const u8) ?Mode {
    const Pair = struct { name: []const u8, mode: Mode };
    const table = [_]Pair{
        .{ .name = "auto", .mode = .auto },
        .{ .name = "kitty", .mode = .kitty },
        .{ .name = "iterm", .mode = .iterm },
        .{ .name = "sixel", .mode = .sixel },
        .{ .name = "braille", .mode = .braille },
        .{ .name = "none", .mode = .none },
    };
    for (table) |p| {
        if (std.mem.eql(u8, value, p.name)) return p.mode;
    }
    return null;
}

/// Resolve the user-requested mode + environment into a concrete
/// protocol. Pure: no I/O, no allocation.
///
/// Order of precedence:
///   1. stdout is not a TTY → `.none` (safety override; gate 8).
///   2. Explicit non-auto mode → echo it back.
///   3. `KITTY_WINDOW_ID` set → `.kitty`.
///   4. `TERM_PROGRAM == "iTerm.app"` → `.iterm`.
///   5. `LC_TERMINAL == "iTerm2"` → `.iterm`.
///   6. `probe_sixel != null` and probe returns true → `.sixel`.
///   7. fall through → `.braille`.
pub fn resolve(opts: ResolveOptions) Protocol {
    if (!opts.stdout_is_tty) return .none;

    switch (opts.mode) {
        .none => return .none,
        .kitty => return .kitty,
        .iterm => return .iterm,
        .sixel => return .sixel,
        .braille => return .braille,
        .auto => {},
    }

    if (opts.env.kitty_window_id) |v| {
        if (v.len > 0) return .kitty;
    }
    if (opts.env.term_program) |v| {
        if (std.mem.eql(u8, v, "iTerm.app")) return .iterm;
    }
    if (opts.env.lc_terminal) |v| {
        if (std.mem.eql(u8, v, "iTerm2")) return .iterm;
    }

    if (opts.probe_sixel) |probe| {
        if (probe()) return .sixel;
    }

    return .braille;
}

/// Parse a DA1 (`Send Device Attributes`) response and return true iff
/// the parameter list contains the literal value `4`, which signals
/// Sixel graphics support. Tolerates leading non-CSI bytes (some
/// terminals echo input keystrokes if probe runs concurrently with
/// user typing) by scanning forward for the `\x1b[?` introducer.
///
/// Example match: `\x1b[?62;1;2;4;6;9;15;22c`  →  true
/// Non-match:     `\x1b[?62;1;2;14;22c`        →  false (14 ≠ 4)
pub fn da1HasSixel(response: []const u8) bool {
    const intro = "\x1b[?";
    const start = std.mem.indexOf(u8, response, intro) orelse return false;
    const after_intro = start + intro.len;
    const end_rel = std.mem.indexOfScalarPos(u8, response, after_intro, 'c') orelse return false;
    const params = response[after_intro..end_rel];

    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, "4")) return true;
    }
    return false;
}

// ── Runtime I/O helpers ─────────────────────────────────────────────
// Not unit-tested. Exercised end-to-end via `awr render` smoke.

/// Read the env vars `resolve` consumes via libc `getenv`. Returned
/// slices borrow from libc's env table; valid for the rest of the
/// process unless `setenv` is called (AWR does not).
pub fn realEnvSnapshot() EnvSnapshot {
    return .{
        .kitty_window_id = getenvSlice("KITTY_WINDOW_ID"),
        .term_program = getenvSlice("TERM_PROGRAM"),
        .lc_terminal = getenvSlice("LC_TERMINAL"),
    };
}

fn getenvSlice(name: []const u8) ?[]const u8 {
    if (!@hasDecl(std.c, "getenv")) return null;
    var name_buf: [64]u8 = undefined;
    if (name.len + 1 > name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const raw = std.c.getenv(@ptrCast(&name_buf)) orelse return null;
    const span = std.mem.sliceTo(raw, 0);
    if (span.len == 0) return null;
    return span;
}

/// True iff stdout is connected to a terminal. Drives the safety
/// override in `resolve`.
pub fn stdoutIsTty() bool {
    return c.isatty(1) != 0;
}

/// Probe the controlling terminal for Sixel support via a DA1 query
/// (`ESC [ c`). 50 ms response window. Best-effort: any I/O failure
/// (no /dev/tty, termios get/set fails, write fails, no response)
/// returns false, which falls through to braille in `resolve`.
///
/// Always restores the original termios via defer — leaving raw mode
/// active on the user's terminal would be a severe regression.
///
/// Opens /dev/tty directly rather than using stdin/stdout so a
/// redirected stdio doesn't break detection on an interactive run.
pub fn probeSixel() bool {
    const fd = c.open("/dev/tty", c.O_RDWR | c.O_NOCTTY);
    if (fd < 0) return false;
    defer _ = c.close(fd);

    var orig: c.struct_termios = undefined;
    if (c.tcgetattr(fd, &orig) != 0) return false;

    var raw = orig;
    const lflags: c.tcflag_t = @as(c.tcflag_t, c.ECHO) | @as(c.tcflag_t, c.ICANON) | @as(c.tcflag_t, c.ISIG);
    raw.c_lflag &= ~lflags;
    raw.c_cc[c.VMIN] = 0;
    raw.c_cc[c.VTIME] = 0;
    if (c.tcsetattr(fd, c.TCSAFLUSH, &raw) != 0) return false;
    defer _ = c.tcsetattr(fd, c.TCSAFLUSH, &orig);

    const query = "\x1b[c";
    // 3-byte writes to a TTY are atomic; treat any short or failed
    // write as "no probe answer" rather than retrying.
    if (c.write(fd, query.ptr, query.len) < 0) return false;

    var pfd = c.struct_pollfd{
        .fd = fd,
        .events = c.POLLIN,
        .revents = 0,
    };
    const ready = c.poll(@ptrCast(&pfd), 1, 50);
    if (ready <= 0) return false;

    var buf: [128]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return false;

    return da1HasSixel(buf[0..@intCast(n)]);
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "parseMode: every keyword maps, unknown returns null" {
    try testing.expectEqual(Mode.auto, parseMode("auto").?);
    try testing.expectEqual(Mode.kitty, parseMode("kitty").?);
    try testing.expectEqual(Mode.iterm, parseMode("iterm").?);
    try testing.expectEqual(Mode.sixel, parseMode("sixel").?);
    try testing.expectEqual(Mode.braille, parseMode("braille").?);
    try testing.expectEqual(Mode.none, parseMode("none").?);
    try testing.expect(parseMode("bogus") == null);
    try testing.expect(parseMode("") == null);
    try testing.expect(parseMode("AUTO") == null); // case-sensitive on purpose
}

test "resolve: non-TTY stdout forces .none regardless of mode" {
    const modes = [_]Mode{ .auto, .kitty, .iterm, .sixel, .braille, .none };
    for (modes) |m| {
        try testing.expectEqual(Protocol.none, resolve(.{
            .mode = m,
            .stdout_is_tty = false,
            .env = .{ .kitty_window_id = "abc" }, // even with strong signal
        }));
    }
}

test "resolve: explicit non-auto mode wins over env" {
    try testing.expectEqual(Protocol.kitty, resolve(.{
        .mode = .kitty,
        .stdout_is_tty = true,
        .env = .{ .term_program = "iTerm.app" }, // ignored under explicit override
    }));
    try testing.expectEqual(Protocol.iterm, resolve(.{
        .mode = .iterm,
        .stdout_is_tty = true,
    }));
    try testing.expectEqual(Protocol.sixel, resolve(.{
        .mode = .sixel,
        .stdout_is_tty = true,
    }));
    try testing.expectEqual(Protocol.braille, resolve(.{
        .mode = .braille,
        .stdout_is_tty = true,
    }));
    try testing.expectEqual(Protocol.none, resolve(.{
        .mode = .none,
        .stdout_is_tty = true,
        .env = .{ .kitty_window_id = "abc" },
    }));
}

test "resolve auto: KITTY_WINDOW_ID detects Kitty" {
    try testing.expectEqual(Protocol.kitty, resolve(.{
        .mode = .auto,
        .stdout_is_tty = true,
        .env = .{ .kitty_window_id = "1" },
    }));
}

test "resolve auto: empty KITTY_WINDOW_ID does not match" {
    try testing.expectEqual(Protocol.braille, resolve(.{
        .mode = .auto,
        .stdout_is_tty = true,
        .env = .{ .kitty_window_id = "" },
    }));
}

test "resolve auto: TERM_PROGRAM=iTerm.app detects iTerm" {
    try testing.expectEqual(Protocol.iterm, resolve(.{
        .mode = .auto,
        .stdout_is_tty = true,
        .env = .{ .term_program = "iTerm.app" },
    }));
}

test "resolve auto: LC_TERMINAL=iTerm2 detects iTerm" {
    try testing.expectEqual(Protocol.iterm, resolve(.{
        .mode = .auto,
        .stdout_is_tty = true,
        .env = .{ .lc_terminal = "iTerm2" },
    }));
}

test "resolve auto: KITTY_WINDOW_ID beats TERM_PROGRAM when both set" {
    try testing.expectEqual(Protocol.kitty, resolve(.{
        .mode = .auto,
        .stdout_is_tty = true,
        .env = .{
            .kitty_window_id = "1",
            .term_program = "iTerm.app",
        },
    }));
}

test "resolve auto: probe returning true picks Sixel" {
    const Probe = struct {
        fn yes() bool {
            return true;
        }
    };
    try testing.expectEqual(Protocol.sixel, resolve(.{
        .mode = .auto,
        .stdout_is_tty = true,
        .probe_sixel = Probe.yes,
    }));
}

test "resolve auto: probe returning false falls through to braille" {
    const Probe = struct {
        fn no() bool {
            return false;
        }
    };
    try testing.expectEqual(Protocol.braille, resolve(.{
        .mode = .auto,
        .stdout_is_tty = true,
        .probe_sixel = Probe.no,
    }));
}

test "resolve auto: no env signal and no probe injected → braille" {
    try testing.expectEqual(Protocol.braille, resolve(.{
        .mode = .auto,
        .stdout_is_tty = true,
    }));
}

test "resolve auto: env signal beats probe (probe never runs)" {
    const Probe = struct {
        fn shouldNotRun() bool {
            // If precedence is wrong this branch fires and the test
            // explicitly fails via the protocol mismatch below.
            return true;
        }
    };
    try testing.expectEqual(Protocol.kitty, resolve(.{
        .mode = .auto,
        .stdout_is_tty = true,
        .env = .{ .kitty_window_id = "1" },
        .probe_sixel = Probe.shouldNotRun,
    }));
}

test "da1HasSixel: parameter list containing 4 matches" {
    try testing.expect(da1HasSixel("\x1b[?62;1;2;4;6;9;15;22c"));
    try testing.expect(da1HasSixel("\x1b[?4c"));
    try testing.expect(da1HasSixel("\x1b[?1;4c"));
    try testing.expect(da1HasSixel("\x1b[?4;1c"));
}

test "da1HasSixel: 14 and 24 do not falsely match" {
    try testing.expect(!da1HasSixel("\x1b[?62;1;14;22c"));
    try testing.expect(!da1HasSixel("\x1b[?24c"));
    try testing.expect(!da1HasSixel("\x1b[?14;24c"));
}

test "da1HasSixel: empty / malformed responses return false" {
    try testing.expect(!da1HasSixel(""));
    try testing.expect(!da1HasSixel("\x1b[?"));
    try testing.expect(!da1HasSixel("\x1b[?62;1;2"));
    try testing.expect(!da1HasSixel("garbage"));
    try testing.expect(!da1HasSixel("\x1b[c")); // our own outgoing query, not a response
}

test "da1HasSixel: tolerates leading bytes before CSI introducer" {
    try testing.expect(da1HasSixel("noise\x1b[?62;4c"));
    try testing.expect(da1HasSixel("\x00\x01\x1b[?4c"));
}

test "da1HasSixel: missing 'c' terminator returns false" {
    try testing.expect(!da1HasSixel("\x1b[?62;1;2;4"));
}
