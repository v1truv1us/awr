/// http1.zig — HTTP/1.1 request serialization and response parsing.
///
/// Key design constraints:
///   - Header order preserved (critical for JA4H fingerprint)
///   - Pseudo-headers (:method, :authority, etc.) are filtered out on write
///   - Supports chunked and content-length bodies on read
///   - Keep-alive connections (Connection: keep-alive by default)
const std = @import("std");

// ── Header types ───────────────────────────────────────────────────────────

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ReadResponseError = error{
    EndOfStreamInStatusLine,
    EndOfStreamInHeaders,
    EndOfStreamInChunkSize,
    EndOfStreamInChunkData,
    EndOfStreamInChunkTerminator,
};

/// Ordered header list. Insertion order preserved — required for fingerprinting.
pub const HeaderList = struct {
    items: std.ArrayList(Header) = .empty,
    /// When true, deinit frees each header's name and value strings.
    /// Set for response-owned headers; leave false for request headers
    /// that reference string literals.
    owns_strings: bool = false,

    pub fn deinit(self: *HeaderList, allocator: std.mem.Allocator) void {
        if (self.owns_strings) {
            for (self.items.items) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
        }
        self.items.deinit(allocator);
    }

    pub fn append(self: *HeaderList, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        try self.items.append(allocator, .{ .name = name, .value = value });
    }

    pub fn get(self: *const HeaderList, name: []const u8) ?[]const u8 {
        for (self.items.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

// ── Request builder ────────────────────────────────────────────────────────

pub const Method = enum { GET, POST, PUT, DELETE, HEAD, OPTIONS, PATCH };

pub const Request = struct {
    method: Method,
    path: []const u8, // e.g. "/index.html" or "/search?q=zig"
    host: []const u8,
    headers: HeaderList = .{},
    body: ?[]const u8 = null,

    /// Serialize as HTTP/1.1 wire format.
    /// Pseudo-headers (starting with ':') are skipped — H2 only.
    pub fn write(self: *const Request, writer: anytype) !void {
        // Request line
        try writer.print("{s} {s} HTTP/1.1\r\n", .{ @tagName(self.method), self.path });

        // Write ordered headers, skip pseudo-headers
        for (self.headers.items.items) |h| {
            if (h.name.len > 0 and h.name[0] == ':') continue;
            try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
        }

        // Blank line
        try writer.writeAll("\r\n");

        // Body
        if (self.body) |b| try writer.writeAll(b);
    }

    /// Add Chrome 132 default headers in canonical fingerprint order.
    pub fn setChrome132Defaults(self: *Request, allocator: std.mem.Allocator) !void {
        // Pseudo-headers first (filtered on write, but stored for H2 reuse)
        try self.headers.append(allocator, ":method", @tagName(self.method));
        try self.headers.append(allocator, ":authority", self.host);
        try self.headers.append(allocator, ":scheme", "https");
        try self.headers.append(allocator, ":path", self.path);
        // HTTP/1.1 Host header — required by RFC 7230 §5.4; skipped in H2
        // because :authority carries the same information.
        try self.headers.append(allocator, "host", self.host);
        // Regular headers in Chrome 132 order
        try self.headers.append(allocator, "accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7");
        try self.headers.append(allocator, "accept-encoding", "gzip, deflate, br, zstd");
        try self.headers.append(allocator, "accept-language", "en-US,en;q=0.9");
        try self.headers.append(allocator, "cache-control", "max-age=0");
        try self.headers.append(allocator, "sec-ch-ua", "\"Not A(Brand\";v=\"8\", \"Chromium\";v=\"132\", \"Google Chrome\";v=\"132\"");
        try self.headers.append(allocator, "sec-ch-ua-mobile", "?0");
        try self.headers.append(allocator, "sec-ch-ua-platform", "\"macOS\"");
        try self.headers.append(allocator, "sec-fetch-dest", "document");
        try self.headers.append(allocator, "sec-fetch-mode", "navigate");
        try self.headers.append(allocator, "sec-fetch-site", "none");
        try self.headers.append(allocator, "sec-fetch-user", "?1");
        try self.headers.append(allocator, "upgrade-insecure-requests", "1");
        try self.headers.append(allocator, "user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36");
    }
};

// ── Response parser ────────────────────────────────────────────────────────

pub const Response = struct {
    status: u16,
    headers: HeaderList,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.headers.deinit(self.allocator);
        self.allocator.free(self.body);
    }

    pub fn isRedirect(self: *const Response) bool {
        return self.status == 301 or self.status == 302 or
            self.status == 307 or self.status == 308;
    }

    pub fn location(self: *const Response) ?[]const u8 {
        return self.headers.get("location");
    }
};

/// Parse an HTTP/1.1 response from `reader`. Caller must call `response.deinit()`.
pub fn readResponse(reader: anytype, allocator: std.mem.Allocator) !Response {
    // Status line: "HTTP/1.1 200 OK\r\n"
    var status_buf: [1024]u8 = undefined;
    const status_line = reader.readUntilDelimiter(&status_buf, '\n') catch |err| switch (err) {
        error.EndOfStream => return ReadResponseError.EndOfStreamInStatusLine,
        else => |e| return e,
    };
    const status = try parseStatus(status_line);

    // Headers (response-owned: deinit must free name+value strings)
    var headers = HeaderList{ .owns_strings = true };
    errdefer headers.deinit(allocator);
    while (true) {
        var header_buf: [64 * 1024]u8 = undefined;
        const line = reader.readUntilDelimiter(&header_buf, '\n') catch |err| switch (err) {
            error.EndOfStream => return ReadResponseError.EndOfStreamInHeaders,
            else => |e| return e,
        };
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break; // blank line = end of headers

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..colon], " ");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " ");

        // Allocate copies for the response-owned header strings
        const name_owned = try allocator.dupe(u8, name);
        errdefer allocator.free(name_owned);
        const value_owned = try allocator.dupe(u8, value);
        errdefer allocator.free(value_owned);

        try headers.items.append(allocator, .{ .name = name_owned, .value = value_owned });
    }

    // Body
    const body = try readBody(reader, &headers, allocator);
    return Response{ .status = status, .headers = headers, .body = body, .allocator = allocator };
}

fn parseStatus(line: []const u8) !u16 {
    // "HTTP/1.1 200 OK\r" or "HTTP/1.1 200 OK"
    const trimmed = std.mem.trimEnd(u8, line, "\r\n");
    // Find second space
    const first_space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return error.BadStatusLine;
    const rest = trimmed[first_space + 1 ..];
    const second_space = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return std.fmt.parseInt(u16, rest[0..second_space], 10) catch return error.BadStatusLine;
}

fn readBody(reader: anytype, headers: *const HeaderList, allocator: std.mem.Allocator) ![]u8 {
    if (headers.get("transfer-encoding")) |te| {
        if (transferEncodingIsChunked(te)) {
            return readChunkedBody(reader, allocator);
        }
    }
    if (headers.get("content-length")) |cl_str| {
        const cl = std.fmt.parseInt(usize, std.mem.trim(u8, cl_str, " "), 10) catch return error.BadContentLength;
        const body = try allocator.alloc(u8, cl);
        try reader.readNoEof(body);
        return body;
    }
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        try body.appendSlice(allocator, buf[0..n]);
    }
    return body.toOwnedSlice(allocator);
}

fn transferEncodingIsChunked(value: []const u8) bool {
    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const coding = std.mem.trim(u8, part, " \t");
        if (coding.len != 0) last = coding;
    }
    return std.ascii.eqlIgnoreCase(last, "chunked");
}

fn readChunkedBody(reader: anytype, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var size_buf: [256]u8 = undefined;
    while (true) {
        // Chunk size line (hex)
        const size_line = reader.readUntilDelimiter(&size_buf, '\n') catch |err| switch (err) {
            error.EndOfStream => return ReadResponseError.EndOfStreamInChunkSize,
            else => |e| return e,
        };
        const trimmed_size_line = std.mem.trimEnd(u8, size_line, "\r\n");
        const ext_start = std.mem.indexOfScalar(u8, trimmed_size_line, ';') orelse trimmed_size_line.len;
        const size_str = trimmed_size_line[0..ext_start];
        const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch return error.BadChunkSize;
        if (chunk_size == 0) break; // last chunk

        const start = buf.items.len;
        try buf.resize(allocator, start + chunk_size);
        reader.readNoEof(buf.items[start..]) catch |err| switch (err) {
            error.EndOfStream => return ReadResponseError.EndOfStreamInChunkData,
            else => |e| return e,
        };

        // Consume trailing CRLF after chunk data
        var crlf: [2]u8 = undefined;
        reader.readNoEof(&crlf) catch |err| switch (err) {
            error.EndOfStream => return ReadResponseError.EndOfStreamInChunkTerminator,
            else => |e| return e,
        };
    }
    while (true) {
        var trailer_buf: [8192]u8 = undefined;
        const line = reader.readUntilDelimiter(&trailer_buf, '\n') catch break;
        if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break;
    }

    return buf.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const TestReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn read(self: *TestReader, dest: []u8) error{}!usize {
        const remaining = self.data[self.pos..];
        const n = @min(dest.len, remaining.len);
        @memcpy(dest[0..n], remaining[0..n]);
        self.pos += n;
        return n;
    }

    fn readUntilDelimiter(self: *TestReader, out: []u8, delim: u8) ![]u8 {
        var len: usize = 0;
        while (len < out.len) {
            const n = try self.read(out[len .. len + 1]);
            if (n == 0) return error.EndOfStream;
            len += n;
            if (out[len - 1] == delim) return out[0..len];
        }
        return error.StreamTooLong;
    }

    fn readNoEof(self: *TestReader, dest: []u8) !void {
        var filled: usize = 0;
        while (filled < dest.len) {
            const n = try self.read(dest[filled..]);
            if (n == 0) return error.EndOfStream;
            filled += n;
        }
    }
};

test "Request.write produces correct request line" {
    const allocator = std.testing.allocator;
    var req = Request{ .method = .GET, .path = "/index.html", .host = "example.com" };
    defer req.headers.deinit(allocator);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try req.write(&w);

    const written = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, written, "GET /index.html HTTP/1.1\r\n"));
}

test "Request.write ends with double CRLF" {
    const allocator = std.testing.allocator;
    var req = Request{ .method = .GET, .path = "/", .host = "example.com" };
    defer req.headers.deinit(allocator);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try req.write(&w);

    const written = w.buffered();
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
}

test "Request.write skips pseudo-headers" {
    const allocator = std.testing.allocator;
    var req = Request{ .method = .GET, .path = "/", .host = "example.com" };
    defer req.headers.deinit(allocator);
    try req.headers.append(allocator, ":method", "GET");
    try req.headers.append(allocator, ":authority", "example.com");
    try req.headers.append(allocator, "accept", "*/*");

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try req.write(&w);

    const written = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, ":method") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, ":authority") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "accept: */*") != null);
}

test "Request.write includes body" {
    const allocator = std.testing.allocator;
    var req = Request{ .method = .POST, .path = "/submit", .host = "example.com", .body = "hello=world" };
    defer req.headers.deinit(allocator);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try req.write(&w);

    const written = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "hello=world") != null);
}

test "Request.setChrome132Defaults writes correct User-Agent" {
    const allocator = std.testing.allocator;
    var req = Request{ .method = .GET, .path = "/", .host = "example.com" };
    defer req.headers.deinit(allocator);
    try req.setChrome132Defaults(allocator);

    const ua = req.headers.get("user-agent");
    try std.testing.expect(ua != null);
    try std.testing.expect(std.mem.indexOf(u8, ua.?, "Chrome/132") != null);
}

test "Request.setChrome132Defaults pseudo-headers come first" {
    const allocator = std.testing.allocator;
    var req = Request{ .method = .GET, .path = "/", .host = "example.com" };
    defer req.headers.deinit(allocator);
    try req.setChrome132Defaults(allocator);

    try std.testing.expectEqualStrings(":method", req.headers.items.items[0].name);
    try std.testing.expectEqualStrings(":authority", req.headers.items.items[1].name);
    try std.testing.expectEqualStrings(":scheme", req.headers.items.items[2].name);
    try std.testing.expectEqualStrings(":path", req.headers.items.items[3].name);
}

test "readResponse parses 200 status" {
    var reader = TestReader{ .data = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" };
    var resp = try readResponse(&reader, std.testing.allocator);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

test "readResponse parses 301 redirect" {
    var reader = TestReader{ .data = "HTTP/1.1 301 Moved Permanently\r\nLocation: https://example.com/\r\nContent-Length: 0\r\n\r\n" };
    var resp = try readResponse(&reader, std.testing.allocator);
    defer resp.deinit();
    try std.testing.expect(resp.isRedirect());
    try std.testing.expectEqualStrings("https://example.com/", resp.location().?);
}

test "readResponse reads content-length body" {
    var reader = TestReader{ .data = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello" };
    var resp = try readResponse(&reader, std.testing.allocator);
    defer resp.deinit();
    try std.testing.expectEqualStrings("hello", resp.body);
}

test "readResponse reads chunked body" {
    var reader = TestReader{ .data = "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n5;ext=1\r\nhello\r\n0\r\n\r\n" };
    var resp = try readResponse(&reader, std.testing.allocator);
    defer resp.deinit();
    try std.testing.expectEqualStrings("hello", resp.body);
}

test "readResponse reads close-delimited body" {
    var reader = TestReader{ .data = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nhello" };
    var resp = try readResponse(&reader, std.testing.allocator);
    defer resp.deinit();
    try std.testing.expectEqualStrings("hello", resp.body);
}

test "HeaderList.get is case-insensitive" {
    const allocator = std.testing.allocator;
    var hl = HeaderList{};
    defer hl.deinit(allocator);
    try hl.append(allocator, "Content-Type", "text/html");
    try std.testing.expectEqualStrings("text/html", hl.get("content-type").?);
    try std.testing.expectEqualStrings("text/html", hl.get("CONTENT-TYPE").?);
}
