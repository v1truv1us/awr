/// sse.zig — Server-Sent Events parser per WHATWG.
///
/// https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream
///
/// Incremental: feed bytes via `feed`, drain completed events via
/// `next`. Internal buffer holds the partial line straddling the
/// current chunk boundary. Suitable for streaming inputs but also
/// works for one-shot whole-body parsing (the Tier 3 — T3.D.1
/// EventSource wire-up uses the latter; real streaming with
/// background reconnect is deferred per the closure record).
///
/// Pure-Zig; no QuickJS or networking dependency.
const std = @import("std");

pub const ParseError = error{OutOfMemory};

/// One dispatched SSE event. `event` defaults to "message" when no
/// `event:` field appeared. `data` already has trailing newline
/// stripped and embedded `\n` joiners between multi-line `data:`
/// records (per spec). `last_event_id` is the most-recent `id:`
/// field's value (may persist across events per spec).
pub const Event = struct {
    event: []const u8, // borrowed slice into Parser-owned buffers
    data: []const u8,
    last_event_id: []const u8,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,

    /// Bytes that haven't yet completed a line. Carried across `feed` calls.
    line_buf: std.ArrayList(u8),
    /// Per-event accumulators. Reset after each dispatch.
    data_buf: std.ArrayList(u8),
    event_type_buf: std.ArrayList(u8),
    /// Persists across events per spec — only mutated by an `id:` field.
    last_event_id_buf: std.ArrayList(u8),
    /// Most recent `retry:` value in milliseconds, or null when never set.
    /// EventSource wrapper consults this for reconnect scheduling.
    retry_ms: ?u32,

    /// Queue of completed events drained by `next`. Each entry holds
    /// owned slices because the underlying buffers get reused on the
    /// next event.
    pending: std.ArrayList(OwnedEvent),
    /// True after the first byte: used to strip a single leading BOM.
    saw_first_byte: bool,
    /// True when the previous chunk ended in CR; if the next chunk
    /// starts with LF, that LF is part of the same CRLF terminator.
    cr_pending: bool,

    const OwnedEvent = struct {
        event: []u8,
        data: []u8,
        last_event_id: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .allocator = allocator,
            .line_buf = .empty,
            .data_buf = .empty,
            .event_type_buf = .empty,
            .last_event_id_buf = .empty,
            .retry_ms = null,
            .pending = .empty,
            .saw_first_byte = false,
            .cr_pending = false,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.line_buf.deinit(self.allocator);
        self.data_buf.deinit(self.allocator);
        self.event_type_buf.deinit(self.allocator);
        self.last_event_id_buf.deinit(self.allocator);
        for (self.pending.items) |e| {
            self.allocator.free(e.event);
            self.allocator.free(e.data);
            self.allocator.free(e.last_event_id);
        }
        self.pending.deinit(self.allocator);
    }

    /// Feed a chunk of bytes from the stream. Lines that complete
    /// (CR / LF / CRLF terminated) are processed; the trailing
    /// partial line stays buffered for the next call.
    pub fn feed(self: *Parser, chunk: []const u8) ParseError!void {
        var i: usize = 0;

        // Strip a single BOM at the very start of the stream.
        if (!self.saw_first_byte and chunk.len >= 3 and
            chunk[0] == 0xEF and chunk[1] == 0xBB and chunk[2] == 0xBF)
        {
            i = 3;
        }
        if (chunk.len > 0) self.saw_first_byte = true;

        // If the previous chunk ended in CR and this one starts with LF,
        // swallow that LF (it's the second half of CRLF).
        if (self.cr_pending and i < chunk.len and chunk[i] == '\n') {
            i += 1;
        }
        self.cr_pending = false;

        while (i < chunk.len) {
            const c = chunk[i];
            if (c == '\n') {
                try self.processLine();
                i += 1;
                continue;
            }
            if (c == '\r') {
                try self.processLine();
                i += 1;
                if (i < chunk.len and chunk[i] == '\n') {
                    i += 1; // consume LF half of CRLF
                } else if (i == chunk.len) {
                    self.cr_pending = true;
                }
                continue;
            }
            try self.line_buf.append(self.allocator, c);
            i += 1;
        }
    }

    /// Mark end of stream: process any final unterminated line, then
    /// (if data accumulated since the last blank line) dispatch it.
    /// EventSource wrappers call this when the underlying connection
    /// closes / response ends.
    pub fn finish(self: *Parser) ParseError!void {
        if (self.line_buf.items.len > 0) try self.processLine();
        // Per spec, closing without a trailing blank line does NOT
        // dispatch the in-progress event — accumulated data is
        // dropped. We follow that rule. If a server sends events
        // without trailing blank lines, those events are lost.
    }

    fn processLine(self: *Parser) ParseError!void {
        defer self.line_buf.clearRetainingCapacity();
        const line = self.line_buf.items;

        // Empty line → dispatch.
        if (line.len == 0) {
            try self.dispatch();
            return;
        }
        // Comment line.
        if (line[0] == ':') return;

        // Field parsing: split on first ':'.
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            // No colon: treat the whole line as a field name with empty value.
            try self.handleField(line, "");
            return;
        };
        const name = line[0..colon];
        var value = line[colon + 1 ..];
        // Spec: strip a single leading space from the value.
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        try self.handleField(name, value);
    }

    fn handleField(self: *Parser, name: []const u8, value: []const u8) ParseError!void {
        if (std.mem.eql(u8, name, "event")) {
            self.event_type_buf.clearRetainingCapacity();
            try self.event_type_buf.appendSlice(self.allocator, value);
        } else if (std.mem.eql(u8, name, "data")) {
            if (self.data_buf.items.len > 0) try self.data_buf.append(self.allocator, '\n');
            try self.data_buf.appendSlice(self.allocator, value);
        } else if (std.mem.eql(u8, name, "id")) {
            // Spec: ignore values containing U+0000 (NUL).
            if (std.mem.indexOfScalar(u8, value, 0) != null) return;
            self.last_event_id_buf.clearRetainingCapacity();
            try self.last_event_id_buf.appendSlice(self.allocator, value);
        } else if (std.mem.eql(u8, name, "retry")) {
            // All ASCII digits → parse as integer ms.
            var all_digits = value.len > 0;
            for (value) |c| {
                if (c < '0' or c > '9') {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) {
                self.retry_ms = std.fmt.parseInt(u32, value, 10) catch null;
            }
        }
        // Unknown fields are silently ignored per spec.
    }

    fn dispatch(self: *Parser) ParseError!void {
        // Spec: if data buffer is empty, do nothing (reset event type
        // but don't fire an event). Otherwise, fire and reset.
        if (self.data_buf.items.len == 0) {
            self.event_type_buf.clearRetainingCapacity();
            return;
        }

        // Strip a single trailing \n (per spec — the last data: line
        // contributed a newline after itself, but we don't want it in
        // the message data).
        var data = self.data_buf.items;
        if (data.len > 0 and data[data.len - 1] == '\n') data = data[0 .. data.len - 1];

        const event_type: []const u8 = if (self.event_type_buf.items.len > 0)
            self.event_type_buf.items
        else
            "message";

        const ev = OwnedEvent{
            .event = try self.allocator.dupe(u8, event_type),
            .data = try self.allocator.dupe(u8, data),
            .last_event_id = try self.allocator.dupe(u8, self.last_event_id_buf.items),
        };
        try self.pending.append(self.allocator, ev);

        // Reset for next event. last_event_id persists per spec.
        self.data_buf.clearRetainingCapacity();
        self.event_type_buf.clearRetainingCapacity();
    }

    /// Pop the oldest pending event. Returned slices live until the
    /// caller calls `freeEvent` (or the parser is deinit'd).
    pub fn next(self: *Parser) ?Event {
        if (self.pending.items.len == 0) return null;
        // FIFO: pop from the front. orderedRemove is O(n) but the
        // queue is short and SSE traffic isn't latency-critical.
        const owned = self.pending.orderedRemove(0);
        // Stash the owned slices on the parser's "to-free" list?
        // Simpler: caller frees via freeEvent. The Event struct
        // exposes the same slices.
        return Event{
            .event = owned.event,
            .data = owned.data,
            .last_event_id = owned.last_event_id,
        };
    }

    /// Free the slices in an Event obtained from `next`. Required —
    /// the parser does NOT track them after handing out.
    pub fn freeEvent(self: *Parser, ev: Event) void {
        self.allocator.free(ev.event);
        self.allocator.free(ev.data);
        self.allocator.free(ev.last_event_id);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "Parser — single message event" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("data: hello\n\n");
    const ev = p.next().?;
    defer p.freeEvent(ev);
    try std.testing.expectEqualStrings("message", ev.event);
    try std.testing.expectEqualStrings("hello", ev.data);
    try std.testing.expectEqualStrings("", ev.last_event_id);
    try std.testing.expect(p.next() == null);
}

test "Parser — custom event type" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("event: ping\ndata: pong\n\n");
    const ev = p.next().?;
    defer p.freeEvent(ev);
    try std.testing.expectEqualStrings("ping", ev.event);
    try std.testing.expectEqualStrings("pong", ev.data);
}

test "Parser — multi-line data joined with \\n" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("data: line1\ndata: line2\ndata: line3\n\n");
    const ev = p.next().?;
    defer p.freeEvent(ev);
    try std.testing.expectEqualStrings("line1\nline2\nline3", ev.data);
}

test "Parser — id field persists across events" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("id: 42\ndata: first\n\ndata: second\n\n");
    const e1 = p.next().?;
    defer p.freeEvent(e1);
    try std.testing.expectEqualStrings("42", e1.last_event_id);
    const e2 = p.next().?;
    defer p.freeEvent(e2);
    try std.testing.expectEqualStrings("42", e2.last_event_id);
}

test "Parser — retry field parsed as milliseconds" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("retry: 3000\n\n");
    try std.testing.expectEqual(@as(u32, 3000), p.retry_ms.?);
    try std.testing.expect(p.next() == null); // retry alone doesn't dispatch
}

test "Parser — comment lines ignored" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed(": heartbeat\ndata: real\n\n");
    const ev = p.next().?;
    defer p.freeEvent(ev);
    try std.testing.expectEqualStrings("real", ev.data);
}

test "Parser — chunk boundary mid-line" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("data: he");
    try p.feed("llo\n\n");
    const ev = p.next().?;
    defer p.freeEvent(ev);
    try std.testing.expectEqualStrings("hello", ev.data);
}

test "Parser — CRLF and CR-only line endings" {
    {
        var p = Parser.init(std.testing.allocator);
        defer p.deinit();
        try p.feed("data: crlf\r\n\r\n");
        const ev = p.next().?;
        defer p.freeEvent(ev);
        try std.testing.expectEqualStrings("crlf", ev.data);
    }
    {
        var p = Parser.init(std.testing.allocator);
        defer p.deinit();
        try p.feed("data: cr\r\r");
        const ev = p.next().?;
        defer p.freeEvent(ev);
        try std.testing.expectEqualStrings("cr", ev.data);
    }
}

test "Parser — CRLF split across chunks" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("data: split\r");
    try p.feed("\n\r\n");
    const ev = p.next().?;
    defer p.freeEvent(ev);
    try std.testing.expectEqualStrings("split", ev.data);
}

test "Parser — BOM stripped at start" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("\xEF\xBB\xBFdata: bom\n\n");
    const ev = p.next().?;
    defer p.freeEvent(ev);
    try std.testing.expectEqualStrings("bom", ev.data);
}

test "Parser — event type resets between events" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("event: special\ndata: a\n\ndata: b\n\n");
    const e1 = p.next().?;
    defer p.freeEvent(e1);
    const e2 = p.next().?;
    defer p.freeEvent(e2);
    try std.testing.expectEqualStrings("special", e1.event);
    try std.testing.expectEqualStrings("message", e2.event);
}

test "Parser — empty data dispatch is suppressed" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("event: noop\n\ndata: real\n\n");
    // First dispatch had no data → no event emitted, but event_type
    // reset before the second dispatch.
    const ev = p.next().?;
    defer p.freeEvent(ev);
    try std.testing.expectEqualStrings("message", ev.event);
    try std.testing.expectEqualStrings("real", ev.data);
}

test "Parser — id with NUL ignored" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try p.feed("id: ok\ndata: a\n\nid: bad\x00val\ndata: b\n\n");
    const e1 = p.next().?;
    defer p.freeEvent(e1);
    const e2 = p.next().?;
    defer p.freeEvent(e2);
    try std.testing.expectEqualStrings("ok", e1.last_event_id);
    // Spec: NUL-bearing id is ignored → previous id persists.
    try std.testing.expectEqualStrings("ok", e2.last_event_id);
}
