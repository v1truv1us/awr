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

const USAGE =
    \\AWR — Agentic Web Runtime
    \\
    \\Usage:
    \\  awr browse <url>             Open URL in interactive terminal browser
    \\  awr render <url> [--width N] [--images=MODE]
    \\                               Load URL, print the rendered terminal text non-interactively
    \\                               --images=auto|kitty|iterm|sixel|braille|none (default: auto)
    \\  awr <url>                    Load URL/path, print JSON {url, status, title, body_text, window_data, tools}
    \\  awr post <url> [k=v ...]     POST URL-encoded form fields, follow redirects, absorb cookies
    \\                                 Set $AWR_COOKIE_JAR to persist cookies across invocations
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

    // Default: treat arg as a URL/path and print the full JSON envelope.
    const url = args[1];
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
    try buf.appendSlice(alloc, ",\"body_text\":");
    try writeJsonStr(&buf, alloc, result.body_text);
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

test "describeLoadError returns stable messages for common failures" {
    try std.testing.expectEqualStrings("invalid URL", describeLoadError(error.InvalidUrl));
    try std.testing.expectEqualStrings("DNS resolution failed", describeLoadError(error.DnsResolutionFailed));
    try std.testing.expectEqualStrings("file not found", describeLoadError(error.FileNotFound));
}
