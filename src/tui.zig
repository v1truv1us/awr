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
};

pub const Size = struct {
    rows: usize,
    cols: usize,
};

pub const Terminal = struct {
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
    original_termios: c.struct_termios,
    raw_enabled: bool,

    pub fn init() !Terminal {
        const stdin_file = std.fs.File.stdin();
        const stdout_file = std.fs.File.stdout();

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
        try self.stdout_file.writeAll("\x1b[?1049h\x1b[?25l");
    }

    pub fn leaveFullscreen(self: *Terminal) !void {
        try self.stdout_file.writeAll("\x1b[?25h\x1b[?1049l");
    }

    pub fn clearScreen(self: *Terminal) !void {
        try self.stdout_file.writeAll("\x1b[H\x1b[2J");
    }

    pub fn readKey(self: *Terminal) !Key {
        const first = try self.readByte();
        switch (first) {
            '\r', '\n' => return .enter,
            0x7f, 0x08 => return .backspace,
            '\t' => return .tab,
            0x1b => {
                const second = (try self.readByteWithTimeout(25)) orelse return .escape;
                if (second == '[') {
                    const third = (try self.readByteWithTimeout(25)) orelse return .escape;
                    return switch (third) {
                        'A' => .arrow_up,
                        'B' => .arrow_down,
                        'C' => .arrow_right,
                        'D' => .arrow_left,
                        'Z' => .shift_tab,
                        else => .escape,
                    };
                }
                return .escape;
            },
            else => return .{ .char = first },
        }
    }

    fn readByte(self: *Terminal) !u8 {
        var buf: [1]u8 = undefined;
        const n = try self.stdin_file.read(&buf);
        if (n == 0) return error.EndOfStream;
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
