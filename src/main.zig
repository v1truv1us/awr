const std = @import("std");
const build_opts = @import("build_opts");
const page_mod = @import("page");
const mock_mod = @import("mock.zig");
const browser_mod = @import("browser.zig");
const telemetry = @import("telemetry");
const image_protocol = @import("image_protocol");
const image_pipeline = @import("image_pipeline");

/// Wall-clock millis without the `Io` capability detour. See
/// `src/util/time.zig` for the rationale; this duplicate avoids
/// re-importing the file from main (which would create a module
/// conflict with `page`'s import).
fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Append `s` URL-encoded into `buf` per `application/x-www-form-urlencoded`.
/// Mirrors browser.zig:appendUrlEncoded — kept duplicated here rather than
/// exported because main and browser are different module roots.
fn appendUrlEncoded(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try buf.append(alloc, c),
            ' ' => try buf.append(alloc, '+'),
            else => {
                try buf.append(alloc, '%');
                const hex = try std.fmt.allocPrint(alloc, "{X:0>2}", .{c});
                defer alloc.free(hex);
                try buf.appendSlice(alloc, hex);
            },
        }
    }
}

fn writeJsonStr(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try list.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                const esc = try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{c});
                defer alloc.free(esc);
                try list.appendSlice(alloc, esc);
            },
            else => try list.append(alloc, c),
        }
    }
    try list.append(alloc, '"');
}

/// True when AWR_DAEMON=1 is set in the environment.
fn daemonModeEnabled() bool {
    const raw = std.c.getenv("AWR_DAEMON") orelse return false;
    const span = std.mem.sliceTo(raw, 0);
    return std.mem.eql(u8, span, "1");
}

/// Resolve the cookie scope key the CLI client should send to the
/// daemon per spec/subspecs/daemon-mode.md §2.4. Resolution order:
///   1. `$AWR_COOKIE_SCOPE` (if set and non-empty) — explicit override
///   2. `sha1($PWD)[:12]` — stable per-project handle
///   3. `"default"` — last-resort fallback when $PWD can't be read
///
/// 12 hex chars = 48 bits of name-space; collision risk for a single
/// user's project list is negligible. Returning a stable hex string
/// (vs a literal $PWD) avoids leaking the working-directory path
/// through the on-disk filename.
fn resolveCookieScope(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("AWR_COOKIE_SCOPE")) |raw| {
        const span = std.mem.sliceTo(raw, 0);
        if (span.len > 0) return allocator.dupe(u8, span);
    }
    if (std.c.getenv("PWD")) |pwd_raw| {
        const pwd = std.mem.sliceTo(pwd_raw, 0);
        if (pwd.len > 0) {
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(pwd);
            var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
            hasher.final(&digest);
            // 12 hex chars = first 6 bytes of the 20-byte digest.
            return std.fmt.allocPrint(allocator, "{x}", .{digest[0..6]});
        }
    }
    return allocator.dupe(u8, "default");
}

/// Resolve the daemon's socket path per spec/subspecs/daemon-mode.md
/// §2.1. Identical to main_daemon.zig:resolveSocketPath; duplicated
/// rather than imported because main and main_daemon are different
/// executables and we don't want main to pull in the daemon module.
fn resolveDaemonSocket(allocator: std.mem.Allocator) ![]u8 {
    const xdg_raw = std.c.getenv("XDG_RUNTIME_DIR");
    const dir: []const u8 = if (xdg_raw != null) blk: {
        const span = std.mem.sliceTo(xdg_raw.?, 0);
        if (span.len == 0) break :blk "/tmp";
        break :blk span;
    } else "/tmp";
    const uid = std.posix.system.geteuid();
    return std.fmt.allocPrint(allocator, "{s}/awrd-{d}.sock", .{ dir, uid });
}

/// AWR_DAEMON=1 path: connect to the daemon socket, send a fetch
/// request for `url`, copy the result envelope to stdout, exit.
/// Format-flag handling mirrors the in-process path so callers can
/// flip AWR_DAEMON without changing their flag set.
fn runViaDaemon(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    format_md: bool,
) !void {
    const sock_path = try resolveDaemonSocket(alloc);
    defer alloc.free(sock_path);

    const ua = try std.Io.net.UnixAddress.init(sock_path);
    var stream = ua.connect(io) catch |err| {
        // Friendly hint: tell the user how to start the daemon
        // rather than dumping a raw errno.
        try stdoutWrite(io,
            "awr: AWR_DAEMON=1 set but cannot connect to daemon socket.\n" ++
            "  Expected at: ");
        try stdoutWrite(io, sock_path);
        try stdoutWrite(io, "\n  Start the daemon with `awrd &`.\n  (");
        const errname = try std.fmt.allocPrint(alloc, "{t}", .{err});
        defer alloc.free(errname);
        try stdoutWrite(io, errname);
        try stdoutWrite(io, ")\n");
        std.process.exit(1);
    };
    defer stream.close(io);

    // Cookie scope per spec §2.4 — defaults to sha1($PWD)[:12], or
    // an explicit AWR_COOKIE_SCOPE override. The daemon validates
    // the name and routes to the per-scope on-disk jar.
    const scope = try resolveCookieScope(alloc);
    defer alloc.free(scope);

    // Build the fetch JSON-RPC body. method/body still default to
    // GET / unset; subsequent slices will surface them through the
    // CLI surface. format_md is applied client-side after the
    // daemon returns the envelope.
    var req_body: std.ArrayList(u8) = .empty;
    defer req_body.deinit(alloc);
    try req_body.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"fetch\",\"params\":{\"url\":");
    try writeJsonStr(&req_body, alloc, url);
    try req_body.appendSlice(alloc, ",\"cookie_scope\":");
    try writeJsonStr(&req_body, alloc, scope);
    try req_body.appendSlice(alloc, "}}");

    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var net_reader = stream.reader(io, &rbuf);
    var net_writer = stream.writer(io, &wbuf);
    try net_writer.interface.print(
        "Content-Length: {d}\r\n\r\n{s}",
        .{ req_body.items.len, req_body.items },
    );
    try net_writer.interface.flush();

    // Read framed response. Headers up to blank line, then exactly
    // Content-Length bytes. Mirrors the parser in
    // tests/integration_runner.zig:readFrame.
    var content_length: ?usize = null;
    var line_buf: [4096]u8 = undefined;
    while (true) {
        var len: usize = 0;
        while (len < line_buf.len) {
            var single: [1]u8 = undefined;
            const n = try net_reader.interface.readSliceShort(&single);
            if (n == 0) return error.UnexpectedEof;
            line_buf[len] = single[0];
            len += 1;
            if (single[0] == '\n') break;
        }
        const line = std.mem.trimEnd(u8, line_buf[0..len], "\r\n");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    const blen = content_length orelse return error.MissingContentLength;
    const resp_body = try alloc.alloc(u8, blen);
    defer alloc.free(resp_body);
    var filled: usize = 0;
    while (filled < blen) {
        const n = try net_reader.interface.readSliceShort(resp_body[filled..]);
        if (n == 0) return error.UnexpectedEof;
        filled += n;
    }

    // Slice 4 forwards the daemon's envelope verbatim to stdout. The
    // shape is `{"jsonrpc":"2.0","id":1,"result":{...envelope...}}`
    // — extract `result` so callers see the same shape as the
    // in-process path. format_md is a future-work item: we'd ask
    // the daemon for body_md, or post-process body_text. Today we
    // just emit the daemon's body_text envelope unchanged when the
    // flag is set so call sites don't crash.
    _ = format_md;
    if (extractJsonRpcResult(resp_body)) |result_slice| {
        try stdoutWrite(io, result_slice);
        try stdoutWrite(io, "\n");
    } else {
        // Daemon returned an error envelope — surface it verbatim
        // and exit non-zero so shell callers see the failure.
        try stdoutWrite(io, resp_body);
        try stdoutWrite(io, "\n");
        std.process.exit(1);
    }
}

/// Extract the value of the top-level `"result"` field from a
/// JSON-RPC response body. Returns null if the response is an error
/// envelope (`"error"` field present) or if `"result"` is missing.
/// Operates on the raw bytes so we don't have to pull a JSON parser
/// into main.zig — the daemon emits a stable shape we can rely on.
fn extractJsonRpcResult(resp: []const u8) ?[]const u8 {
    // If error envelope, give up.
    if (std.mem.indexOf(u8, resp, "\"error\":") != null) return null;

    const needle = "\"result\":";
    const start = std.mem.indexOf(u8, resp, needle) orelse return null;
    const v_start = start + needle.len;
    if (v_start >= resp.len) return null;

    // Walk until we close the outer JSON value of result. Track
    // brace/bracket depth ignoring depths inside strings.
    var i: usize = v_start;
    var depth: i32 = 0;
    var in_string = false;
    var escape = false;
    while (i < resp.len) : (i += 1) {
        const c = resp[i];
        if (in_string) {
            if (escape) { escape = false; continue; }
            if (c == '\\') { escape = true; continue; }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                depth -= 1;
                if (depth == 0) return resp[v_start .. i + 1];
                if (depth < 0) {
                    // Closed at an outer level — result is not an
                    // object/array. Return up to here.
                    return resp[v_start..i];
                }
            },
            ',' => if (depth == 0) return resp[v_start..i],
            else => {},
        }
    }
    return resp[v_start..];
}

const USAGE =
    \\AWR — Agentic Web Runtime
    \\
    \\Usage:
    \\  awr browse <url>             Open URL in interactive terminal browser
    \\  awr render <url> [--width N] [--images=MODE]
    \\                               Load URL, print the rendered terminal text non-interactively
    \\                               --images=auto|kitty|iterm|sixel|braille|none (default: auto)
    \\  awr <url> [--format=md]      Load URL/path, print JSON envelope. Default body_text is plain text;
    \\                                 `--format=markdown` (or `=md`) swaps it for the Markdown extraction
    \\                                 (chrome-filtered, headings + inline links preserved) under `body_md`.
    \\                                 Set `AWR_DAEMON=1` to route through `awrd` instead of running
    \\                                 the page pipeline in-process (warmer connection pool).
    \\  awr post <url> [k=v ...]     POST URL-encoded form fields, follow redirects, absorb cookies
    \\                                 Set $AWR_COOKIE_JAR to persist cookies across invocations
    \\  awr submit <url> [--form=SEL] [k=v ...]
    \\                               Load page, find <form>, merge user fields with hidden inputs (CSRF),
    \\                                 POST to the form's action. --form selects by #id (default: first form)
    \\  awr extract <url>            Load page, emit Markdown (token-friendly for LLM agents).
    \\                                 Drops nav/footer chrome, preserves headings/lists/inline links.
    \\  awr cookies [show|clear]     Show or clear the persistent cookie jar (uses $AWR_COOKIE_JAR).
    \\  awr tools <url>              Load URL/path, print the JSON array of registered WebMCP tools
    \\  awr call <url> <name> <json> Load URL/path, invoke tool <name> with <json> args, print result envelope
    \\  awr mock [--port N]          Serve experiments/ over HTTP (default: 127.0.0.1:7777)
    \\  awr --version                Print version and exit
    \\
    \\<url> may be an http(s):// URL, a file:// URL, or a local filesystem path.
    \\
;

fn stdoutWrite(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn describeLoadError(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidUrl => "invalid URL",
        error.DnsResolutionFailed => "DNS resolution failed",
        error.ConnectionFailed => "connection failed",
        error.TlsNotAvailable => "TLS setup or handshake failed",
        error.TooManyRedirects => "too many redirects",
        error.FileNotFound => "file not found",
        error.AccessDenied => "access denied",
        error.NotDir => "path contains a non-directory segment",
        error.IsDir => "path points to a directory, not a file",
        error.NameTooLong => "path is too long",
        error.FileTooBig => "file exceeds the supported size limit",
        error.NoSpaceLeft => "out of disk space",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
}

fn fatalLoadError(action: []const u8, location: []const u8, err: anyerror) noreturn {
    std.process.fatal("error {s} {s}: {s} ({s})", .{
        action,
        location,
        describeLoadError(err),
        @errorName(err),
    });
}

/// Telemetry-aware variant of `fatalLoadError`. Records the error
/// onto the session metrics and emits before calling fatal, so failed
/// fetches show up in aggregate logs alongside successful ones.
/// std.process.fatal calls posix.exit which does NOT run deferred
/// cleanup, including the deferred telemetry.emit at the top of
/// main — without this manual emit, the error path would be invisible
/// to telemetry.
fn fatalLoadErrorWithMetrics(
    metrics: *telemetry.SessionMetrics,
    alloc: std.mem.Allocator,
    io: std.Io,
    action: []const u8,
    location: []const u8,
    err: anyerror,
) noreturn {
    metrics.error_kind = @errorName(err);
    metrics.error_message = describeLoadError(err);
    telemetry.emit(metrics, alloc, io);
    fatalLoadError(action, location, err);
}

/// Detect whether `awr call` returned the error envelope shape
/// `{ "ok": false, ... }` (with or without spaces after the colon).
fn isFailedCallEnvelope(out: []const u8) bool {
    const s = std.mem.trim(u8, out, " \t\r\n");
    const tight = std.mem.indexOf(u8, s, "\"ok\":false");
    if (tight) |i| return i < 24;
    const spaced = std.mem.indexOf(u8, s, "\"ok\": false");
    if (spaced) |i| return i < 24;
    return false;
}

/// Load a page from either an http(s):// URL or a local file path.
/// The returned PageResult is owned by the caller.
fn loadPage(
    p: *page_mod.Page,
    alloc: std.mem.Allocator,
    io: std.Io,
    location: []const u8,
) !page_mod.PageResult {
    if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) {
        return p.navigate(location);
    }

    const path: []const u8 = if (std.mem.startsWith(u8, location, "file://"))
        location[7..]
    else
        location;

    const html = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024));
    defer alloc.free(html);

    const synthetic_url = if (std.mem.startsWith(u8, location, "file://"))
        try alloc.dupe(u8, location)
    else
        try std.fmt.allocPrint(alloc, "file://{s}", .{path});
    defer alloc.free(synthetic_url);

    return p.processHtml(synthetic_url, 200, html);
}

// We accept `Init.Minimal` instead of the richer `Init` so that Zig's
// startup code in `std/start.zig` skips its own `DebugAllocator` setup.
// That allocator captures a stack trace on every allocation, which in Zig
// 0.16 panics with `integer overflow` inside
// `std/debug/SelfInfo/Elf.zig:{460,472}` — the VDSO's `phdr.vaddr =
// 0xffffffffff700000` is added to `info.addr` without wrapping arithmetic.
// The buggy code path runs before `main`, so instrumenting here is too
// late; the only in-repo fix is to never take that path. Upstream needs
// `info.addr +% phdr.vaddr` on those two lines (line 497 already does
// this for the .LOAD case).
pub fn main(minimal: std.process.Init.Minimal) !void {
    comptime {
        if (!@import("builtin").link_libc)
            @compileError("awr must be built with -Dlink_libc or `exe.linkLibC()` — " ++
                "std.heap.c_allocator requires libc");
    }
    // `c_allocator` because build.zig links libc; this matches what
    // `std/start.zig` does in ReleaseSafe/Fast and keeps the CLI well away
    // from the `DebugAllocator` path above.
    const alloc = std.heap.c_allocator;

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();

    var threaded: std.Io.Threaded = .init(alloc, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const args = try minimal.args.toSlice(arena_state.allocator());

    if (args.len < 2) {
        try stdoutWrite(io, USAGE);
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
        const out = try std.fmt.allocPrint(alloc, "0.0.{s}\n", .{build_opts.git_hash});
        defer alloc.free(out);
        try stdoutWrite(io, out);
        return;
    }

    // `awr --help` / `-h` / `help` — print USAGE and exit 0.
    // Distinct from the args.len < 2 branch above, which prints USAGE and
    // exits 1 because no argument was supplied at all (error condition).
    if (std.mem.eql(u8, args[1], "--help") or
        std.mem.eql(u8, args[1], "-h") or
        std.mem.eql(u8, args[1], "help"))
    {
        try stdoutWrite(io, USAGE);
        return;
    }

    // Subcommand: awr mock [--port N] [--root DIR]
    if (std.mem.eql(u8, args[1], "mock")) {
        var port: u16 = 7777;
        var root: []const u8 = "experiments";
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
                port = std.fmt.parseInt(u16, args[i + 1], 10) catch {
                    std.process.fatal("mock: --port expects a u16, got '{s}'", .{args[i + 1]});
                };
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--root") and i + 1 < args.len) {
                root = args[i + 1];
                i += 1;
            } else {
                std.process.fatal("mock: unknown arg '{s}'", .{args[i]});
            }
        }
        try mock_mod.run(alloc, io, "127.0.0.1", port, root);
        return;
    }

    // Subcommand: awr browse <url>
    if (std.mem.eql(u8, args[1], "browse")) {
        if (args.len < 3) {
            try stdoutWrite(io, "usage: awr browse <url>\n");
            std.process.exit(1);
        }
        try browser_mod.run(alloc, io, args[2]);
        return;
    }

    // Subcommand: awr render <url>
    // Non-interactive sibling of `awr browse`. Loads the URL, runs it
    // through the same renderBrowseModel pipeline the TUI uses, and prints
    // the plain rendered text + link footnotes to stdout. Useful for
    // agents, scripts, smoke tests, and CI verification of the render
    // pipeline without needing a real TTY.
    if (std.mem.eql(u8, args[1], "render")) {
        if (args.len < 3) {
            try stdoutWrite(io, "usage: awr render <url> [--width N] [--images=MODE]\n");
            std.process.exit(1);
        }
        var width: usize = 78;
        // The Mode is parsed from CLI here; the runtime Protocol resolution
        // (env + isatty + Sixel probe) is performed in the rendering path
        // (sub-step 4f) where it is consumed. Validating the flag eagerly
        // gives users an immediate error on typos.
        var image_mode: image_protocol.Mode = .auto;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--width") and i + 1 < args.len) {
                width = std.fmt.parseInt(usize, args[i + 1], 10) catch {
                    std.process.fatal("render: --width expects an integer, got '{s}'", .{args[i + 1]});
                };
                i += 1;
            } else if (std.mem.startsWith(u8, args[i], "--images=")) {
                const value = args[i]["--images=".len..];
                image_mode = image_protocol.parseMode(value) orelse {
                    std.process.fatal("render: --images expects auto|kitty|iterm|sixel|braille|none, got '{s}'", .{value});
                };
            } else if (std.mem.eql(u8, args[i], "--images") and i + 1 < args.len) {
                image_mode = image_protocol.parseMode(args[i + 1]) orelse {
                    std.process.fatal("render: --images expects auto|kitty|iterm|sixel|braille|none, got '{s}'", .{args[i + 1]});
                };
                i += 1;
            } else {
                std.process.fatal("render: unknown arg '{s}'", .{args[i]});
            }
        }
        // Resolve the requested mode against the runtime environment.
        // Non-TTY stdout forces `.none` (gate 8 — `awr render | tee` must
        // stay escape-free regardless of `--images=…`). The Sixel CSI probe
        // is wired only when the user requested `auto`; explicit modes skip
        // the 50 ms latency. The resolved Protocol flows through
        // RenderOptions; sub-step 4f teaches `browser.zig:draw` to act on
        // it. Today the model layer is still text-only.
        const resolved_protocol = image_protocol.resolve(.{
            .mode = image_mode,
            .stdout_is_tty = image_protocol.stdoutIsTty(),
            .env = image_protocol.realEnvSnapshot(),
            .probe_sixel = if (image_mode == .auto) &image_protocol.probeSixel else null,
        });

        // Per-session telemetry — same pattern as the default URL path.
        // The render path emits rendered terminal text instead of a
        // JSON envelope, so `envelope_bytes` reflects screen.text.len.
        var metrics = telemetry.SessionMetrics.init();
        metrics.url = args[2];
        defer telemetry.emit(&metrics, alloc, io);

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit();
        p.metrics_sink = &metrics;
        var result = loadPage(&p, alloc, io, args[2]) catch |err| {
            fatalLoadErrorWithMetrics(&metrics, alloc, io, "loading", args[2], err);
        };
        defer result.deinit();

        // Build the image pipeline only when a real protocol resolved.
        // `.none` (non-TTY override or `--images=none`) skips pipeline
        // construction so we never spend time fetching images we won't
        // emit.
        var pipeline_storage: ?image_pipeline.Pipeline = null;
        defer if (pipeline_storage) |*pl| pl.deinit();
        var image_lookup_opt: ?page_mod.ImageLookup = null;
        if (resolved_protocol != .none) {
            if (image_pipeline.build(alloc, &p, args[2], resolved_protocol, .{
                .max_width_cells = @intCast(width),
            })) |pl| {
                pipeline_storage = pl;
                image_lookup_opt = pipeline_storage.?.lookup();
            } else |_| {
                // Pipeline construction failed; render falls back to
                // text alt-refs. No fatal — image rendering is best-
                // effort, the page text is the primary deliverable.
            }
        }

        var screen = try p.renderBrowseModel(alloc, &result, .{
            .max_width = width,
            .ansi_colors = false,
            .show_links = true,
            // Non-interactive output: emit the References footer so the
            // inline [N] link markers have a URL list to resolve against.
            // The browse profile defaults to suppressing the footer for
            // interactive use; here we override to true.
            .show_references = true,
            .show_images = true,
            .image_protocol = resolved_protocol,
            .image_lookup = image_lookup_opt,
        });
        defer screen.deinit();
        try stdoutWrite(io, screen.text);
        if (screen.text.len == 0 or screen.text[screen.text.len - 1] != '\n') {
            try stdoutWrite(io, "\n");
        }
        metrics.envelope_bytes = screen.text.len;
        return;
    }

    // Subcommand: awr tools <url>
    if (std.mem.eql(u8, args[1], "tools")) {
        if (args.len < 3) {
            try stdoutWrite(io, "usage: awr tools <url>\n");
            std.process.exit(1);
        }
        var metrics = telemetry.SessionMetrics.init();
        metrics.url = args[2];
        defer telemetry.emit(&metrics, alloc, io);

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit();
        p.metrics_sink = &metrics;
        var result = loadPage(&p, alloc, io, args[2]) catch |err| {
            fatalLoadErrorWithMetrics(&metrics, alloc, io, "loading", args[2], err);
        };
        defer result.deinit();
        const tj = result.tools_json orelse "[]";
        try stdoutWrite(io, tj);
        try stdoutWrite(io, "\n");
        metrics.envelope_bytes = tj.len + 1; // +1 for newline
        return;
    }

    // Subcommand: awr call <url> <tool> <json>
    if (std.mem.eql(u8, args[1], "call")) {
        if (args.len < 5) {
            try stdoutWrite(io, "usage: awr call <url> <tool-name> <json-args>\n");
            std.process.exit(1);
        }
        var metrics = telemetry.SessionMetrics.init();
        metrics.url = args[2];
        defer telemetry.emit(&metrics, alloc, io);

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit();
        p.metrics_sink = &metrics;
        var result = loadPage(&p, alloc, io, args[2]) catch |err| {
            fatalLoadErrorWithMetrics(&metrics, alloc, io, "loading", args[2], err);
        };
        defer result.deinit();
        const out = try p.callTool(args[3], args[4]);
        defer alloc.free(out);
        try stdoutWrite(io, out);
        try stdoutWrite(io, "\n");
        metrics.envelope_bytes = out.len + 1;
        // Tool-call failures are app-level, not transport-level: the
        // page loaded fine (200) but the JS tool returned `{ok:false}`.
        // Surface this distinct from network errors via error_kind so
        // aggregate logs can split "couldn't reach the page" from
        // "the page's tool said no".
        if (isFailedCallEnvelope(out)) {
            metrics.error_kind = "ToolCallFailed";
            telemetry.emit(&metrics, alloc, io);
            std.process.exit(1);
        }
        return;
    }

    // Subcommand: awr post <url> [field=value ...]
    //
    // Programmatic POST with cookie support — the scriptable counterpart
    // to the TUI form-submit path. Each field=value arg is URL-encoded
    // and joined into an `application/x-www-form-urlencoded` body.
    // Cookies absorbed from the response (and any redirect chain) round-
    // trip through the page's cookie jar; combined with `AWR_COOKIE_JAR`
    // this enables cross-process sign-in flows:
    //
    //   export AWR_COOKIE_JAR=$HOME/.local/state/awr/cookies.txt
    //   awr post   https://site/login user=alice password=hunter2
    //   awr        https://site/dashboard   # carries the session cookie
    //
    // Output is the same JSON envelope as the default fetch path; the
    // status / url / body_text reflect the post-redirect final response.
    if (std.mem.eql(u8, args[1], "post")) {
        if (args.len < 3) {
            try stdoutWrite(io, "usage: awr post <url> [field=value ...]\n");
            std.process.exit(1);
        }
        const url = args[2];

        // Build the URL-encoded body from arg pairs.
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);
        var first = true;
        for (args[3..]) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
                try stdoutWrite(io, "awr post: each field arg must be `name=value`\n");
                std.process.exit(1);
            };
            if (!first) try body.append(alloc, '&');
            first = false;
            try appendUrlEncoded(alloc, &body, pair[0..eq]);
            try body.append(alloc, '=');
            try appendUrlEncoded(alloc, &body, pair[eq + 1 ..]);
        }

        var metrics = telemetry.SessionMetrics.init();
        metrics.url = url;
        defer telemetry.emit(&metrics, alloc, io);

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit();
        p.metrics_sink = &metrics;

        var result = p.navigatePost(url, body.items) catch |err| {
            fatalLoadErrorWithMetrics(&metrics, alloc, io, "posting", url, err);
        };
        defer result.deinit();

        // Same JSON envelope as the default path. Reuses the writeJsonStr
        // helper at the top of this file.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.append(alloc, '{');
        try out.appendSlice(alloc, "\"url\":");
        try writeJsonStr(&out, alloc, result.url);
        const status_str = try std.fmt.allocPrint(alloc, ",\"status\":{d}", .{result.status});
        defer alloc.free(status_str);
        try out.appendSlice(alloc, status_str);
        try out.appendSlice(alloc, ",\"title\":");
        if (result.title) |t| try writeJsonStr(&out, alloc, t) else try out.appendSlice(alloc, "null");
        try out.appendSlice(alloc, ",\"body_text\":");
        try writeJsonStr(&out, alloc, result.body_text);
        try out.appendSlice(alloc, ",\"window_data\":");
        if (result.window_data) |wd| try out.appendSlice(alloc, wd) else try out.appendSlice(alloc, "null");
        try out.appendSlice(alloc, ",\"tools\":");
        if (result.tools_json) |tj| try out.appendSlice(alloc, tj) else try out.appendSlice(alloc, "[]");
        try out.appendSlice(alloc, "}\n");
        try stdoutWrite(io, out.items);
        metrics.envelope_bytes = out.items.len;
        return;
    }

    // Subcommand: awr cookies [show|clear]
    //
    // Inspect or wipe the persistent cookie jar at `$AWR_COOKIE_JAR`.
    // Useful for debugging sign-in flows ("did the session cookie get
    // absorbed?") and for forced logouts ("clear and start fresh").
    //
    // No subcommand or `show`: print one cookie per line in the format
    //   <domain><TAB><path><TAB><name>=<value><TAB>expires=<unix|session>
    // with HttpOnly_ prefix on the domain when the cookie is HttpOnly.
    //
    // `clear`: empties the in-memory jar and writes an empty jar file.
    if (std.mem.eql(u8, args[1], "cookies")) {
        const sub = if (args.len >= 3) args[2] else "show";
        if (!std.mem.eql(u8, sub, "show") and !std.mem.eql(u8, sub, "clear")) {
            try stdoutWrite(io, "usage: awr cookies [show|clear]\n");
            std.process.exit(1);
        }

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit(); // saveCookiesToDisk runs here for clear path

        if (std.mem.eql(u8, sub, "clear")) {
            // Empty the jar in memory; deinit will persist the empty
            // file to disk if AWR_COOKIE_JAR is set.
            for (p.client.cookies.cookies.items) |*c| c.deinit(p.client.cookies.allocator);
            p.client.cookies.cookies.clearAndFree(p.client.cookies.allocator);
            try stdoutWrite(io, "cleared.\n");
            return;
        }

        // show: emit a tab-separated table.
        if (p.client.cookies.cookies.items.len == 0) {
            try stdoutWrite(io, "(empty)\n");
            return;
        }
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        for (p.client.cookies.cookies.items) |c| {
            line.clearRetainingCapacity();
            if (c.http_only) try line.appendSlice(alloc, "HttpOnly_");
            try line.appendSlice(alloc, c.domain);
            try line.append(alloc, '\t');
            try line.appendSlice(alloc, c.path);
            try line.append(alloc, '\t');
            try line.appendSlice(alloc, c.name);
            try line.append(alloc, '=');
            try line.appendSlice(alloc, c.value);
            try line.append(alloc, '\t');
            if (c.expires) |exp| {
                const exp_str = try std.fmt.allocPrint(alloc, "expires={d}", .{exp});
                defer alloc.free(exp_str);
                try line.appendSlice(alloc, exp_str);
            } else {
                try line.appendSlice(alloc, "expires=session");
            }
            try line.append(alloc, '\n');
            try stdoutWrite(io, line.items);
        }
        return;
    }

    // Subcommand: awr extract <url>
    //
    // Token-friendly Markdown output for LLM/agent consumption. Drops
    // nav/footer/aside chrome (via browse_heuristics), preserves
    // headings, lists, blockquotes, inline `[text](url)` links, code
    // blocks, and images. Typical 30–40% smaller than the default
    // body_text for content-rich pages, with structure preserved.
    //
    //   awr extract https://en.wikipedia.org/wiki/Web_browser > page.md
    //
    // Output is raw Markdown to stdout (no JSON wrapping). Pair with
    // `awr submit` for an authed-page reading flow:
    //
    //   awr submit https://site/login user=alice password=hunter2
    //   awr extract https://site/dashboard
    if (std.mem.eql(u8, args[1], "extract")) {
        if (args.len < 3) {
            try stdoutWrite(io, "usage: awr extract <url>\n");
            std.process.exit(1);
        }
        const url = args[2];
        var metrics = telemetry.SessionMetrics.init();
        metrics.url = url;
        defer telemetry.emit(&metrics, alloc, io);

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit();
        p.metrics_sink = &metrics;

        var result = loadPage(&p, alloc, io, url) catch |err| {
            fatalLoadErrorWithMetrics(&metrics, alloc, io, "loading", url, err);
        };
        defer result.deinit();

        const md = try p.extractMarkdown(alloc);
        defer alloc.free(md);
        try stdoutWrite(io, md);
        if (md.len == 0 or md[md.len - 1] != '\n') try stdoutWrite(io, "\n");
        metrics.envelope_bytes = md.len;
        return;
    }

    // Subcommand: awr submit <page-url> [--form=SELECTOR] [field=value ...]
    //
    // Single-shot form submit: load the page, find the form (default:
    // first <form>; --form=#id picks by selector), merge user-provided
    // field=value overrides with the form's own attribute values
    // (hidden inputs, CSRF tokens, pre-populated text), POST to the
    // form's resolved action.
    //
    // Replaces the awkward two-step pattern of `awr <login-url>` →
    // grep CSRF token → `awr post <action> csrf=... user=... password=...`.
    //
    //   export AWR_COOKIE_JAR=$HOME/.local/state/awr/cookies.txt
    //   awr submit https://site/login user=alice password=hunter2
    //
    // Output is the same JSON envelope as the default fetch path, with
    // status / url / title / body_text reflecting the post-redirect
    // final response.
    if (std.mem.eql(u8, args[1], "submit")) {
        if (args.len < 3) {
            try stdoutWrite(io, "usage: awr submit <url> [--form=SELECTOR] [field=value ...]\n");
            std.process.exit(1);
        }
        const url = args[2];

        // Parse remaining args: --form=SEL is a flag; everything else is field=value.
        var form_selector: ?[]const u8 = null;
        var overrides: std.ArrayList(page_mod.Page.FieldOverride) = .empty;
        defer overrides.deinit(alloc);
        for (args[3..]) |arg| {
            if (std.mem.startsWith(u8, arg, "--form=")) {
                form_selector = arg["--form=".len..];
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, arg, '=') orelse {
                try stdoutWrite(io, "awr submit: each field arg must be `name=value` (or --form=SEL)\n");
                std.process.exit(1);
            };
            try overrides.append(alloc, .{ .name = arg[0..eq], .value = arg[eq + 1 ..] });
        }

        var metrics = telemetry.SessionMetrics.init();
        metrics.url = url;
        defer telemetry.emit(&metrics, alloc, io);

        var p = try page_mod.Page.init(alloc, io);
        defer p.deinit();
        p.metrics_sink = &metrics;

        // Step 1: load the page so the DOM is populated and any cookies
        // set on this response (server-rotated CSRF) are absorbed.
        var get_result = loadPage(&p, alloc, io, url) catch |err| {
            fatalLoadErrorWithMetrics(&metrics, alloc, io, "loading", url, err);
        };
        defer get_result.deinit();

        // Step 2: gather form fields → (target_url, body, method).
        var sub = p.gatherFormSubmission(get_result.url, form_selector, overrides.items, alloc) catch |err| {
            const msg = switch (err) {
                error.NoCurrentDocument => "awr submit: page failed to parse",
                error.FormNotFound => "awr submit: --form selector matched no form",
                error.NoFormFound => "awr submit: page contains no <form> element",
                else => "awr submit: failed to gather form submission",
            };
            try stdoutWrite(io, msg);
            try stdoutWrite(io, "\n");
            std.process.exit(1);
        };
        defer page_mod.Page.freeFormSubmission(alloc, &sub);

        // Step 3: submit. POST through navigatePost; for GET, append body
        // as query string and load normally.
        var result: page_mod.PageResult = if (sub.method == .POST)
            p.navigatePost(sub.target_url, sub.body) catch |err| {
                fatalLoadErrorWithMetrics(&metrics, alloc, io, "submitting", sub.target_url, err);
            }
        else blk: {
            // GET: append body as query string with `?` or `&` joiner.
            const has_q = std.mem.indexOfScalar(u8, sub.target_url, '?') != null;
            const sep: u8 = if (has_q) '&' else '?';
            const full_url = if (sub.body.len == 0)
                try alloc.dupe(u8, sub.target_url)
            else
                try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{ sub.target_url, sep, sub.body });
            defer alloc.free(full_url);
            break :blk loadPage(&p, alloc, io, full_url) catch |err| {
                fatalLoadErrorWithMetrics(&metrics, alloc, io, "submitting", full_url, err);
            };
        };
        defer result.deinit();

        // Same JSON envelope as the default + post paths.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.append(alloc, '{');
        try out.appendSlice(alloc, "\"url\":");
        try writeJsonStr(&out, alloc, result.url);
        const status_str = try std.fmt.allocPrint(alloc, ",\"status\":{d}", .{result.status});
        defer alloc.free(status_str);
        try out.appendSlice(alloc, status_str);
        try out.appendSlice(alloc, ",\"title\":");
        if (result.title) |t| try writeJsonStr(&out, alloc, t) else try out.appendSlice(alloc, "null");
        try out.appendSlice(alloc, ",\"body_text\":");
        try writeJsonStr(&out, alloc, result.body_text);
        try out.appendSlice(alloc, ",\"window_data\":");
        if (result.window_data) |wd| try out.appendSlice(alloc, wd) else try out.appendSlice(alloc, "null");
        try out.appendSlice(alloc, ",\"tools\":");
        if (result.tools_json) |tj| try out.appendSlice(alloc, tj) else try out.appendSlice(alloc, "[]");
        try out.appendSlice(alloc, "}\n");
        try stdoutWrite(io, out.items);
        metrics.envelope_bytes = out.items.len;
        return;
    }

    // Default: treat arg as a URL/path and print the full JSON envelope.
    //
    // Optional `--format=markdown` flag swaps the `body_text` field for
    // the Markdown extraction (chrome-filtered, headings/lists/inline
    // links preserved — same shape as `awr extract` but inside the
    // existing JSON envelope so JSON-aware callers don't have to switch
    // subcommands). Default `--format=json` keeps prior behavior.
    var format_md = false;
    var url_arg: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--format=markdown") or std.mem.eql(u8, arg, "--format=md")) {
            format_md = true;
        } else if (std.mem.eql(u8, arg, "--format=json")) {
            format_md = false;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try stdoutWrite(io, "awr: unknown flag: ");
            try stdoutWrite(io, arg);
            try stdoutWrite(io, "\n");
            std.process.exit(1);
        } else if (url_arg == null) {
            url_arg = arg;
        } else {
            try stdoutWrite(io, "awr: unexpected positional arg: ");
            try stdoutWrite(io, arg);
            try stdoutWrite(io, "\n");
            std.process.exit(1);
        }
    }
    const url = url_arg orelse {
        try stdoutWrite(io, "awr: missing URL\n");
        std.process.exit(1);
    };

    // AWR_DAEMON=1 routes the default fetch through the daemon's
    // JSON-RPC `fetch` method instead of running the page pipeline
    // in-process. Same envelope shape on stdout — agents and pipes
    // can flip the env var without changing call sites. Connection-
    // refused exits with a friendly hint so users discover `awrd`.
    //
    // Slice 4 minimal: only the default fetch path honors the var.
    // tools / call / extract / submit will pick it up in subsequent
    // slices once the daemon implements those methods.
    if (daemonModeEnabled()) {
        try runViaDaemon(alloc, io, url, format_md);
        return;
    }

    const timing_on = std.c.getenv("AWR_TIMING") != null;

    // Telemetry sink — populated through the fetch pipeline whenever
    // AWR_TELEMETRY is set, ignored otherwise. The sink lives across
    // every phase; emission happens in `defer` so even early exits via
    // unhandled errors still get a record. Attaching to Page via
    // `metrics_sink` is what plumbs the sub-phase timings.
    var metrics = telemetry.SessionMetrics.init();
    metrics.url = url;
    defer telemetry.emit(&metrics, alloc, io);

    const t_startup_done = if (timing_on or telemetry.resolveDest(alloc) catch .none != .none) nowMs() else 0;
    var p = try page_mod.Page.init(alloc, io);
    defer p.deinit();
    p.metrics_sink = &metrics;
    if (t_startup_done != 0) {
        const elapsed = nowMs() - t_startup_done;
        if (timing_on) std.debug.print("[timing] page_init={d}ms\n", .{elapsed});
        metrics.page_init_ms = elapsed;
    }

    const t_process_start = nowMs();
    var result = loadPage(&p, alloc, io, url) catch |err| {
        fatalLoadErrorWithMetrics(&metrics, alloc, io, "fetching", url, err);
    };
    defer result.deinit();
    metrics.process_html_ms = nowMs() - t_process_start - metrics.navigate_fetch_ms;
    if (metrics.process_html_ms < 0) metrics.process_html_ms = 0;

    const t_render_start = if (timing_on or p.metrics_sink != null) nowMs() else 0;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.append(alloc, '{');
    try buf.appendSlice(alloc, "\"url\":");
    try writeJsonStr(&buf, alloc, result.url);
    const status_str = try std.fmt.allocPrint(alloc, ",\"status\":{d}", .{result.status});
    defer alloc.free(status_str);
    try buf.appendSlice(alloc, status_str);
    try buf.appendSlice(alloc, ",\"title\":");
    if (result.title) |t| try writeJsonStr(&buf, alloc, t) else try buf.appendSlice(alloc, "null");
    if (format_md) {
        // Swap the `body_text` field for the Markdown extraction. Caller
        // can still tell the format from the field name.
        const md = try p.extractMarkdown(alloc);
        defer alloc.free(md);
        try buf.appendSlice(alloc, ",\"body_md\":");
        try writeJsonStr(&buf, alloc, md);
    } else {
        try buf.appendSlice(alloc, ",\"body_text\":");
        try writeJsonStr(&buf, alloc, result.body_text);
    }
    try buf.appendSlice(alloc, ",\"window_data\":");
    if (result.window_data) |wd| try buf.appendSlice(alloc, wd) else try buf.appendSlice(alloc, "null");
    try buf.appendSlice(alloc, ",\"tools\":");
    if (result.tools_json) |tj| try buf.appendSlice(alloc, tj) else try buf.appendSlice(alloc, "[]");
    try buf.appendSlice(alloc, "}\n");

    try stdoutWrite(io, buf.items);
    if (t_render_start != 0) {
        const elapsed = nowMs() - t_render_start;
        if (timing_on) std.debug.print("[timing] json_emit={d}ms ({d}B)\n", .{ elapsed, buf.items.len });
        metrics.json_emit_ms = elapsed;
        metrics.envelope_bytes = buf.items.len;
    }
}

test "isFailedCallEnvelope detects {ok:false}" {
    try std.testing.expect(isFailedCallEnvelope("{\"ok\":false,\"error\":\"ToolNotFound\"}"));
    try std.testing.expect(isFailedCallEnvelope("{\"ok\": false, \"error\": \"ToolNotFound\"}"));
    try std.testing.expect(!isFailedCallEnvelope("{\"ok\":true,\"value\":{}}"));
}

test "resolveCookieScope returns 12 hex chars or default" {
    // We can't safely setenv inside a test (libc setenv leaks across
    // tests on some platforms). Resolution depends on env that the
    // test runner provides — at minimum we expect either a valid
    // 12-hex scope (sha1($PWD)[:12]) or the literal "default" if
    // PWD wasn't set. Both shapes are valid — we just check the
    // returned slice is allocator-owned and non-empty.
    const allocator = std.testing.allocator;
    const scope = try resolveCookieScope(allocator);
    defer allocator.free(scope);
    try std.testing.expect(scope.len > 0);
    // If sha1[:12] path was taken, scope is exactly 12 lowercase
    // hex chars. Otherwise it's "default" or whatever
    // AWR_COOKIE_SCOPE happens to be in the env. Validate the hex
    // shape only when length matches.
    if (scope.len == 12) {
        for (scope) |c| try std.testing.expect(
            (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'),
        );
    }
}

test "describeLoadError returns stable messages for common failures" {
    try std.testing.expectEqualStrings("invalid URL", describeLoadError(error.InvalidUrl));
    try std.testing.expectEqualStrings("DNS resolution failed", describeLoadError(error.DnsResolutionFailed));
    try std.testing.expectEqualStrings("file not found", describeLoadError(error.FileNotFound));
}
