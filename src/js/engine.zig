/// engine.zig — QuickJS-NG JS engine wrapper for AWR Phase 2.
///
/// Provides JsEngine (a Runtime + Context pair) with a minimal Web API
/// surface pre-installed:
///
///   console.log / console.warn / console.error
///   setTimeout / clearTimeout / setInterval / clearInterval (stubs)
///   structuredClone (stub — returns undefined, sufficient for Phase 2)
///
/// The JS↔DOM bridge (document.querySelector, addEventListener, …) is
/// installed separately by dom/bridge.zig after the DOM tree is ready.
///
/// Phase 2 limitations:
///   - setTimeout/setInterval are synchronous no-ops: callbacks are never
///     called.  Phase 3 will wire them into the libxev timer queue.
///   - fetch() is not yet installed; scripts that call fetch() will throw
///     ReferenceError.  Phase 2 installs a minimal stub that throws a
///     descriptive error.
///   - console output goes to stderr by default.  Tests that need to
///     capture output can pass a custom ConsoleSink.
const std = @import("std");
const qjs = @import("quickjs");
const event_loop_mod = @import("event_loop.zig");

/// Local copy of the wallClockMillis helper. Inlined here (rather than
/// importing src/util/time.zig) because the JS engine is a Zig module
/// rooted at src/js/engine.zig and can't reach sibling directories.
/// Mirrors src/util/time.zig:wallClockMillis exactly — keep in sync.
fn wallClockMillis() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

pub const EventLoop = event_loop_mod.EventLoop;

/// Adapter interface the JS `fetch()` binding calls to perform the HTTP
/// request. Page supplies a concrete impl wired to its `Client`; unit
/// tests can inject their own. Returns JSON-serialisable `{status, body,
/// url}` on success, or an error the binding translates to a rejected
/// Promise.
pub const FetchHost = struct {
    pub const Method = enum { GET, POST };

    /// Request shape passed from the JS bridge to the host. `body` is null
    /// for GET; for POST it is the URL-encoded body bytes (the polyfill
    /// stringifies URLSearchParams). Borrowed slices — the host must copy
    /// before async work and free its copy in the response path.
    pub const Request = struct {
        url: []const u8,
        method: Method = .GET,
        body: ?[]const u8 = null,
    };

    pub const Response = struct {
        status: u16,
        body: []u8,
        url: []u8,
        headers_json: []u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Response) void {
            self.allocator.free(self.body);
            self.allocator.free(self.url);
            self.allocator.free(self.headers_json);
        }
    };

    ptr: *anyopaque,
    fetchFn: *const fn (ptr: *anyopaque, req: Request) anyerror!Response,

    /// Backwards-compat shortcut for callers that only need GET.
    pub fn fetch(self: FetchHost, url: []const u8) anyerror!Response {
        return self.fetchFn(self.ptr, .{ .url = url });
    }

    /// Full fetch entry — call with a `Request` to use POST or specify a body.
    pub fn fetchWith(self: FetchHost, req: Request) anyerror!Response {
        return self.fetchFn(self.ptr, req);
    }
};

// ── Public error type ─────────────────────────────────────────────────────

pub const JsError = error{
    RuntimeInitFailed,
    ContextInitFailed,
    EvalException,
    OutOfMemory,
    PropertySetFailed,
};

// ── Console sink ──────────────────────────────────────────────────────────

/// Output sink for console.* messages.
/// Inject a custom one in tests to capture output without touching stderr.
pub const ConsoleSink = struct {
    pub const Level = enum { log, warn, err };
    /// Called synchronously inside the JS engine callback.
    ptr: *anyopaque,
    writeFn: *const fn (ptr: *anyopaque, level: Level, msg: []const u8) void,

    pub fn write(self: ConsoleSink, level: Level, msg: []const u8) void {
        self.writeFn(self.ptr, level, msg);
    }

    /// Default sink: write to stderr with level prefix.
    pub fn defaultSink() ConsoleSink {
        const S = struct {
            fn w(_: *anyopaque, level: Level, msg: []const u8) void {
                const prefix: []const u8 = switch (level) {
                    .log => "[JS]  ",
                    .warn => "[JS warn] ",
                    .err => "[JS error] ",
                };
                std.debug.print("{s}{s}\n", .{ prefix, msg });
            }
        };
        // We only need the function pointer; the ptr is ignored by default sink.
        return .{ .ptr = @ptrFromInt(1), .writeFn = S.w };
    }
};

// ── Per-context host data stored as context opaque ───────────────────────

const HostData = struct {
    sink: ConsoleSink,
    allocator: std.mem.Allocator,
    /// Optional extension pointer set by dom/bridge.zig.
    /// Allows the DOM bridge callbacks to reach the Document without
    /// a circular import dependency.
    extension: ?*anyopaque = null,
    /// Optional libxev-backed timer queue installed by Page.
    /// When null, setTimeout/setInterval degrade to the stub behaviour.
    event_loop: ?*EventLoop = null,
    /// Optional fetch implementation installed by Page. When null,
    /// `fetch()` returns a rejected Promise.
    fetch_host: ?FetchHost = null,
    /// Wall-clock millisecond deadline for the currently-executing
    /// synchronous script. 0 = unbounded. The QuickJS interrupt handler
    /// dereferences this on every poll and aborts execution when the
    /// deadline is exceeded. Set via `JsEngine.setEvalDeadlineMs`,
    /// cleared via `JsEngine.clearEvalDeadline`.
    eval_deadline_ms: i64 = 0,
};

/// Expose HostData so bridge.zig can retrieve it via ctx.getOpaque().
pub const EngineHostData = HostData;

// ── JsEngine ─────────────────────────────────────────────────────────────

/// Owns a QuickJS Runtime + Context with Web APIs installed.
/// Must outlive any JsValue references obtained from it.
pub const JsEngine = struct {
    rt: *qjs.Runtime,
    ctx: *qjs.Context,
    host: *HostData,
    allocator: std.mem.Allocator,

    /// Default per-script wall-clock budget. Same order of magnitude as
    /// Page.drainAll's load-phase budget. Override via AWR_JS_BUDGET_MS
    /// env var when wrapping individual eval sites.
    pub const DEFAULT_EVAL_BUDGET_MS: u64 = 2_000;

    /// Conservative memory cap per Runtime — gtag.js-class scripts sit
    /// well under this, and any page using more is almost certainly
    /// pathological. Defense in depth alongside the deadline handler.
    pub const DEFAULT_MEMORY_LIMIT: usize = 128 * 1024 * 1024; // 128 MB

    /// Create a new JsEngine.
    /// `sink` defaults to stderr if null.
    pub fn init(allocator: std.mem.Allocator, sink: ?ConsoleSink) JsError!JsEngine {
        const rt = qjs.Runtime.init() catch return JsError.RuntimeInitFailed;
        errdefer rt.deinit();

        rt.setMaxStackSize(4 * 1024 * 1024); // 4 MB
        rt.setMemoryLimit(DEFAULT_MEMORY_LIMIT);

        const ctx = qjs.Context.init(rt) catch return JsError.ContextInitFailed;
        errdefer ctx.deinit();

        // Allocate host data and store in context opaque so callbacks can
        // reach it. eval_deadline_ms lives on HostData so the QuickJS
        // interrupt handler has a stable pointer that survives both context
        // resets and JsEngine being moved by-value.
        const host = allocator.create(HostData) catch return JsError.OutOfMemory;
        errdefer allocator.destroy(host);
        host.* = .{
            .sink = sink orelse ConsoleSink.defaultSink(),
            .allocator = allocator,
        };
        ctx.setOpaque(HostData, host);

        // Install the deadline-aware interrupt handler. The handler reads
        // `host.eval_deadline_ms`; while it's 0, every poll is a no-op
        // (~10k-bytecode cadence × ~ns per check = negligible overhead).
        rt.setInterruptHandler(i64, &host.eval_deadline_ms, evalDeadlineHandler);

        var engine = JsEngine{
            .rt = rt,
            .ctx = ctx,
            .host = host,
            .allocator = allocator,
        };
        try engine.installWebApis();
        return engine;
    }

    /// Bound the next js.eval call to `ms_from_now` wall-clock milliseconds.
    /// The QuickJS interrupt handler aborts execution with InternalError
    /// when the deadline is exceeded. Pair with `clearEvalDeadline()` —
    /// idiomatic usage is `defer self.clearEvalDeadline()`.
    pub fn setEvalDeadlineMs(self: *JsEngine, ms_from_now: u64) void {
        const now = wallClockMillis();
        self.host.eval_deadline_ms = now +| @as(i64, @intCast(@min(ms_from_now, std.math.maxInt(i64))));
    }

    /// Clear the eval deadline. After this, scripts run unbounded again.
    pub fn clearEvalDeadline(self: *JsEngine) void {
        self.host.eval_deadline_ms = 0;
    }

    pub fn deinit(self: *JsEngine) void {
        self.ctx.deinit();
        self.rt.deinit();
        self.allocator.destroy(self.host);
    }

    /// Tear down the JS Context and bring up a fresh one on the same Runtime.
    ///
    /// Reuses the (expensive) `qjs.Runtime` and the `HostData` allocation —
    /// only the per-context state (globals, JIT caches, value table) is
    /// rebuilt. Used by `Page.processHtml` between navigations to clear
    /// state bleed without paying the full Runtime+Context teardown cost.
    ///
    /// On failure leaves the engine in its prior state (rollback-safe):
    /// the new context is created before the old one is destroyed, and the
    /// `self.ctx` swap only commits when `installWebApis` succeeds.
    ///
    /// The caller is still responsible for re-attaching pointers that live
    /// outside the engine — typically `event_loop.reset(self.ctx)` to
    /// re-point any libxev timer entries at the new context.
    pub fn reset(self: *JsEngine) JsError!void {
        const new_ctx = qjs.Context.init(self.rt) catch return JsError.ContextInitFailed;
        var success = false;
        defer if (!success) new_ctx.deinit();

        new_ctx.setOpaque(HostData, self.host);

        const old_ctx = self.ctx;
        self.ctx = new_ctx;
        errdefer self.ctx = old_ctx;

        try self.installWebApis();

        success = true;
        old_ctx.deinit();
    }

    // ── Evaluation ──────────────────────────────────────────────────────

    /// Evaluate a JS source string.
    /// Returns JsError.EvalException on any JS exception.
    pub fn eval(self: *JsEngine, source: []const u8, filename: [:0]const u8) JsError!void {
        const result = self.ctx.eval(source, filename, .{});
        defer result.deinit(self.ctx);
        if (result.isException()) return JsError.EvalException;
    }

    /// Evaluate and return a boolean result.
    /// Caller must ensure the expression yields a boolean.
    pub fn evalBool(self: *JsEngine, source: []const u8) JsError!bool {
        const result = self.ctx.eval(source, "<eval>", .{});
        defer result.deinit(self.ctx);
        if (result.isException()) return JsError.EvalException;
        return result.toBool(self.ctx) catch false;
    }

    /// Evaluate and return a heap-allocated string result.
    /// Caller owns the returned slice and must free it.
    pub fn evalString(self: *JsEngine, source: []const u8) JsError![]u8 {
        const val = self.ctx.eval(source, "<eval>", .{});
        if (val.isException()) {
            val.deinit(self.ctx);
            return JsError.EvalException;
        }
        defer val.deinit(self.ctx);
        const cstr = val.toCString(self.ctx) orelse return JsError.OutOfMemory;
        defer self.ctx.freeCString(cstr);
        return self.allocator.dupe(u8, std.mem.span(cstr));
    }

    /// Drain the microtask / Promise job queue.
    pub fn drainMicrotasks(self: *JsEngine) void {
        while (self.rt.isJobPending()) {
            _ = self.rt.executePendingJob() catch break;
        }
    }

    // ── Property helpers ────────────────────────────────────────────────

    /// Set a named property on the global object.
    pub fn setGlobal(self: *JsEngine, name: [:0]const u8, val: qjs.Value) JsError!void {
        const global = self.ctx.getGlobalObject();
        defer global.deinit(self.ctx);
        global.setPropertyStr(self.ctx, name, val) catch return JsError.PropertySetFailed;
    }

    // ── Web API installation ────────────────────────────────────────────

    fn installWebApis(self: *JsEngine) JsError!void {
        try self.installConsole();
        try self.installTimers();
        try self.installFetch();
        try self.installStructuredClone();
        try self.installUrlSearchParams();
        try self.installMatchMedia();
    }

    /// Called by Page after constructing its EventLoop.
    /// Safe to call multiple times; the most recent pointer wins.
    pub fn attachEventLoop(self: *JsEngine, loop: *EventLoop) void {
        self.host.event_loop = loop;
    }

    /// Called by Page after constructing its HTTP client wrapper.
    pub fn attachFetchHost(self: *JsEngine, host: FetchHost) void {
        self.host.fetch_host = host;
    }

    // ── console ─────────────────────────────────────────────────────────

    fn installConsole(self: *JsEngine) JsError!void {
        const ctx = self.ctx;
        const console = qjs.Value.initObject(ctx);
        defer console.deinit(ctx);

        const logFn = qjs.Value.initCFunction(ctx, consoleLog, "log", 1);
        const warnFn = qjs.Value.initCFunction(ctx, consoleWarn, "warn", 1);
        const errorFn = qjs.Value.initCFunction(ctx, consoleError, "error", 1);
        defer logFn.deinit(ctx);
        defer warnFn.deinit(ctx);
        defer errorFn.deinit(ctx);

        console.setPropertyStr(ctx, "log", logFn.dup(ctx)) catch return JsError.PropertySetFailed;
        console.setPropertyStr(ctx, "warn", warnFn.dup(ctx)) catch return JsError.PropertySetFailed;
        console.setPropertyStr(ctx, "error", errorFn.dup(ctx)) catch return JsError.PropertySetFailed;

        try self.setGlobal("console", console.dup(ctx));
    }

    // ── console callbacks ───────────────────────────────────────────────

    fn consoleLog(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
        consoleWrite(ctx, .log, args);
        return qjs.Value.undefined;
    }

    fn consoleWarn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
        consoleWrite(ctx, .warn, args);
        return qjs.Value.undefined;
    }

    fn consoleError(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
        consoleWrite(ctx, .err, args);
        return qjs.Value.undefined;
    }

    fn consoleWrite(maybe_ctx: ?*qjs.Context, level: ConsoleSink.Level, args: []const @import("quickjs").c.JSValue) void {
        const ctx = maybe_ctx orelse return;
        const host = ctx.getOpaque(HostData) orelse return;

        // Build a space-separated string from all arguments using JSON.stringify
        // for objects and direct toString for primitives.
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);

        for (args, 0..) |raw_arg, i| {
            const arg: qjs.Value = @bitCast(raw_arg);
            if (i > 0) _ = w.writeByte(' ') catch {};

            if (arg.isString()) {
                const cstr = arg.toCString(ctx);
                if (cstr) |s| {
                    _ = w.writeAll(std.mem.span(s)) catch {};
                    ctx.freeCString(s);
                }
            } else if (arg.isNumber() or arg.isBool() or arg.isNull() or arg.isUndefined()) {
                const cstr = arg.toCString(ctx);
                if (cstr) |s| {
                    _ = w.writeAll(std.mem.span(s)) catch {};
                    ctx.freeCString(s);
                }
            } else {
                // Objects/arrays: call JS_JSONStringify directly on the value.
                const json_val = arg.jsonStringify(ctx, qjs.Value.undefined, qjs.Value.undefined);
                defer json_val.deinit(ctx);
                if (!json_val.isException() and !json_val.isUndefined()) {
                    if (json_val.toCString(ctx)) |s| {
                        _ = w.writeAll(std.mem.span(s)) catch {};
                        ctx.freeCString(s);
                    } else {
                        _ = w.writeAll("[object]") catch {};
                    }
                } else {
                    _ = w.writeAll("[object]") catch {};
                }
            }
        }

        host.sink.write(level, w.buffered());
    }

    // ── timers — libxev-backed when an EventLoop is attached ─────────────

    fn installTimers(self: *JsEngine) JsError!void {
        const ctx = self.ctx;
        const setTimeoutFn = qjs.Value.initCFunction(ctx, setTimeoutCb, "setTimeout", 2);
        const clearTimeoutFn = qjs.Value.initCFunction(ctx, clearTimerCb, "clearTimeout", 1);
        const setIntervalFn = qjs.Value.initCFunction(ctx, setIntervalCb, "setInterval", 2);
        const clearIntervalFn = qjs.Value.initCFunction(ctx, clearTimerCb, "clearInterval", 1);
        defer setTimeoutFn.deinit(ctx);
        defer clearTimeoutFn.deinit(ctx);
        defer setIntervalFn.deinit(ctx);
        defer clearIntervalFn.deinit(ctx);

        try self.setGlobal("setTimeout", setTimeoutFn.dup(ctx));
        try self.setGlobal("clearTimeout", clearTimeoutFn.dup(ctx));
        try self.setGlobal("setInterval", setIntervalFn.dup(ctx));
        try self.setGlobal("clearInterval", clearIntervalFn.dup(ctx));
    }

    fn scheduleTimer(
        ctx: *qjs.Context,
        args: []const @import("quickjs").c.JSValue,
        repeating: bool,
    ) qjs.Value {
        const host = ctx.getOpaque(HostData) orelse return qjs.Value.initInt32(0);
        const el = host.event_loop orelse return qjs.Value.initInt32(0);
        if (args.len < 1) return qjs.Value.initInt32(0);
        const cb_raw: qjs.Value = @bitCast(args[0]);
        if (!cb_raw.isFunction(ctx)) return qjs.Value.initInt32(0);

        var delay_ms: u64 = 0;
        if (args.len >= 2) {
            const d: qjs.Value = @bitCast(args[1]);
            if (d.toFloat64(ctx)) |f| {
                if (f > 0) delay_ms = @intFromFloat(@min(f, @as(f64, std.math.maxInt(u32))));
            } else |_| {}
        }

        const owned = cb_raw.dup(ctx);
        const id = el.schedule(owned, delay_ms, repeating) catch {
            owned.deinit(ctx);
            return qjs.Value.initInt32(0);
        };
        return qjs.Value.initInt32(@intCast(id));
    }

    fn setTimeoutCb(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
        const c = ctx orelse return qjs.Value.initInt32(0);
        return scheduleTimer(c, args, false);
    }

    fn setIntervalCb(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
        const c = ctx orelse return qjs.Value.initInt32(0);
        return scheduleTimer(c, args, true);
    }

    fn clearTimerCb(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
        const c = ctx orelse return qjs.Value.undefined;
        const host = c.getOpaque(HostData) orelse return qjs.Value.undefined;
        const el = host.event_loop orelse return qjs.Value.undefined;
        if (args.len < 1) return qjs.Value.undefined;
        const id_arg: qjs.Value = @bitCast(args[0]);
        const id_i = id_arg.toInt32(c) catch return qjs.Value.undefined;
        if (id_i > 0) el.cancel(@intCast(id_i));
        return qjs.Value.undefined;
    }

    // ── fetch — wired to the Page's HTTP client via FetchHost ────────────

    fn installFetch(self: *JsEngine) JsError!void {
        const ctx = self.ctx;
        // Native primitive: returns Promise<{ok, status, url, body}>.
        // Arity 3 — (url, method, body). The polyfill always passes all three.
        const rawFn = qjs.Value.initCFunction(ctx, rawFetchCb, "__awr_rawFetch__", 3);
        defer rawFn.deinit(ctx);
        try self.setGlobal("__awr_rawFetch__", rawFn.dup(ctx));

        // Thin JS polyfill: wraps the raw object in a Response-like.
        try self.eval(FETCH_POLYFILL, "<fetch-polyfill>");
    }

    fn rawFetchCb(
        ctx: ?*qjs.Context,
        _: qjs.Value,
        args: []const @import("quickjs").c.JSValue,
    ) qjs.Value {
        const c = ctx orelse return qjs.Value.undefined;
        const promise = qjs.Value.initPromiseCapability(c);

        const fail = struct {
            fn reject(cc: *qjs.Context, p: qjs.Value.Promise, msg: []const u8) qjs.Value {
                const err = qjs.Value.initError(cc);
                const msg_val = qjs.Value.initStringLen(cc, msg);
                err.setPropertyStr(cc, "message", msg_val) catch {};
                const rr = p.reject.call(cc, qjs.Value.undefined, &.{err});
                rr.deinit(cc);
                err.deinit(cc);
                p.resolve.deinit(cc);
                p.reject.deinit(cc);
                return p.value;
            }
        }.reject;

        if (args.len < 1) return fail(c, promise, "fetch() requires a URL");
        const url_arg: qjs.Value = @bitCast(args[0]);
        const cstr = url_arg.toCString(c) orelse return fail(c, promise, "fetch() URL must be a string");
        defer c.freeCString(cstr);
        const url_slice = std.mem.span(cstr);

        // Optional arg[1]: method ("GET" or "POST"). Default GET when absent
        // or non-string (the polyfill always passes a string, but defend here).
        var method: FetchHost.Method = .GET;
        if (args.len >= 2) {
            const method_arg: qjs.Value = @bitCast(args[1]);
            if (method_arg.toCString(c)) |mstr| {
                defer c.freeCString(mstr);
                const m = std.mem.span(mstr);
                if (std.ascii.eqlIgnoreCase(m, "POST")) {
                    method = .POST;
                }
            }
        }

        // Optional arg[2]: body bytes (already URL-encoded by the polyfill
        // when the caller passed a URLSearchParams). Borrowed for the
        // duration of fetch_host.fetchWith — the host must copy before any
        // async work since the QuickJS-managed buffer is freed via
        // freeCString below.
        var body_cstr: ?[*:0]const u8 = null;
        var body_slice: ?[]const u8 = null;
        if (args.len >= 3) {
            const body_arg: qjs.Value = @bitCast(args[2]);
            // Treat null/undefined as no body. Only string is accepted; the
            // polyfill stringifies URLSearchParams before calling raw().
            if (!body_arg.isNull() and !body_arg.isUndefined()) {
                body_cstr = body_arg.toCString(c) orelse return fail(c, promise, "fetch() body must be a string");
                body_slice = std.mem.span(body_cstr.?);
            }
        }
        defer if (body_cstr) |bc| c.freeCString(bc);

        const host = c.getOpaque(HostData) orelse return fail(c, promise, "fetch() host not configured");
        const fetch_host = host.fetch_host orelse return fail(c, promise, "fetch() not available in this context");

        var resp = fetch_host.fetchWith(.{
            .url = url_slice,
            .method = method,
            .body = body_slice,
        }) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fetch failed: {t}", .{err}) catch "fetch failed";
            return fail(c, promise, msg);
        };
        defer resp.deinit();

        // Build {ok, status, url, body, headersJson}.
        const obj = qjs.Value.initObject(c);
        const ok_val = qjs.Value.initBool(resp.status >= 200 and resp.status < 300);
        const status_val = qjs.Value.initInt32(@intCast(resp.status));
        const url_val = qjs.Value.initStringLen(c, resp.url);
        const body_val = qjs.Value.initStringLen(c, resp.body);
        const headers_val = qjs.Value.initStringLen(c, resp.headers_json);

        obj.setPropertyStr(c, "ok", ok_val) catch {};
        obj.setPropertyStr(c, "status", status_val) catch {};
        obj.setPropertyStr(c, "url", url_val) catch {};
        obj.setPropertyStr(c, "body", body_val) catch {};
        obj.setPropertyStr(c, "headersJson", headers_val) catch {};

        const rr = promise.resolve.call(c, qjs.Value.undefined, &.{obj});
        rr.deinit(c);
        obj.deinit(c);
        promise.resolve.deinit(c);
        promise.reject.deinit(c);
        return promise.value;
    }

    const FETCH_POLYFILL =
        \\(function () {
        \\  'use strict';
        \\  var raw = globalThis.__awr_rawFetch__;
        \\  if (typeof raw !== 'function') return;
        \\  globalThis.fetch = function fetch(resource, init) {
        \\    if (typeof resource !== 'string') {
        \\      return Promise.reject(new Error('fetch: only string URLs are currently supported'));
        \\    }
        \\    var url = resource;
        \\    init = init || {};
        \\    if (typeof init !== 'object') {
        \\      return Promise.reject(new Error('fetch: init must be an object when provided'));
        \\    }
        \\    var keys = Object.keys(init);
        \\    for (var i = 0; i < keys.length; i += 1) {
        \\      var key = keys[i];
        \\      if (key !== 'method' && key !== 'body') {
        \\        return Promise.reject(new Error('fetch: init.' + key + ' is not currently supported'));
        \\      }
        \\    }
        \\    var method = init.method ? String(init.method).toUpperCase() : 'GET';
        \\    if (method !== 'GET' && method !== 'POST') {
        \\      return Promise.reject(new Error('fetch: only GET and POST are currently supported'));
        \\    }
        \\    var body = null;
        \\    if (init.body != null) {
        \\      // URLSearchParams stringifies to application/x-www-form-urlencoded
        \\      // form. Plain strings pass through. Objects/FormData/streams are
        \\      // not in MVP scope per spec/subspecs/agent-browser.md §3.
        \\      if (typeof init.body === 'string') {
        \\        body = init.body;
        \\      } else if (typeof URLSearchParams !== 'undefined' && init.body instanceof URLSearchParams) {
        \\        body = init.body.toString();
        \\      } else {
        \\        return Promise.reject(new Error('fetch: init.body must be a string or URLSearchParams'));
        \\      }
        \\    }
        \\    if (method === 'GET' && body !== null) {
        \\      return Promise.reject(new Error('fetch: GET requests cannot have a body'));
        \\    }
        \\    return raw(url, method, body).then(function (r) {
        \\      var body = r.body;
        \\      var headersMap = {};
        \\      try { headersMap = r.headersJson ? JSON.parse(r.headersJson) : {}; } catch (e) {}
        \\      return {
        \\        ok: r.ok,
        \\        status: r.status,
        \\        url: r.url,
        \\        __headersMap: headersMap,
        \\        headers: {
        \\          get: function (name) {
        \\            if (!name) return null;
        \\            var key = String(name).toLowerCase();
        \\            return Object.prototype.hasOwnProperty.call(headersMap, key) ? headersMap[key] : null;
        \\          }
        \\        },
        \\        text:    function () { return Promise.resolve(body); },
        \\        json:    function () { return Promise.resolve(JSON.parse(body)); },
        \\        arrayBuffer: function () { return Promise.resolve(new TextEncoder().encode(body).buffer); },
        \\      };
        \\    });
        \\  };
        \\})();
    ;

    // ── structuredClone — JSON-round-trip polyfill (covers MVP FR-3.5) ───

    fn installStructuredClone(self: *JsEngine) JsError!void {
        try self.eval(STRUCTURED_CLONE_POLYFILL, "<structured-clone>");
    }

    // ── URLSearchParams polyfill ────────────────────────────────────────
    //
    // Required by spec/subspecs/agent-browser.md §2. QuickJS-NG ships no
    // URLSearchParams; without this polyfill, the fetch() and XHR body
    // shapes documented in the spec cannot be constructed by callers.

    fn installUrlSearchParams(self: *JsEngine) JsError!void {
        try self.eval(URLSEARCHPARAMS_POLYFILL, "<url-search-params>");
    }

    const URLSEARCHPARAMS_POLYFILL = @embedFile("url_search_params.js");

    /// `window.matchMedia(query)` — agent-runtime stub.
    ///
    /// Returns a `MediaQueryList` shape with `matches: false`, the original
    /// query string, and no-op `addEventListener` / `removeEventListener` /
    /// `addListener` / `removeListener` / `dispatchEvent` / `onchange`.
    /// This is enough to satisfy the feature-detection paths in scripts
    /// like react.dev's `(prefers-color-scheme: dark)` probe — they call
    /// `.matches` and ignore the result if false, then `.addEventListener`
    /// for runtime updates that AWR will never emit.
    ///
    /// Deliberately does NOT attempt real CSS Media Query evaluation: AWR
    /// has no viewport, no display medium, no reduced-motion preference.
    /// Returning `matches: false` is the conservative answer.
    fn installMatchMedia(self: *JsEngine) JsError!void {
        try self.eval(MATCH_MEDIA_POLYFILL, "<match-media>");
    }

    const MATCH_MEDIA_POLYFILL =
        \\(function () {
        \\  if (typeof globalThis.matchMedia === 'function') return;
        \\  function MediaQueryList(query) {
        \\    this.media = String(query == null ? '' : query);
        \\    this.matches = false;
        \\    this.onchange = null;
        \\  }
        \\  MediaQueryList.prototype.addListener = function () {};
        \\  MediaQueryList.prototype.removeListener = function () {};
        \\  MediaQueryList.prototype.addEventListener = function () {};
        \\  MediaQueryList.prototype.removeEventListener = function () {};
        \\  MediaQueryList.prototype.dispatchEvent = function () { return false; };
        \\  globalThis.matchMedia = function matchMedia(query) {
        \\    return new MediaQueryList(query);
        \\  };
        \\})();
    ;


    const STRUCTURED_CLONE_POLYFILL =
        \\(function () {
        \\  if (typeof globalThis.structuredClone === 'function') return;
        \\  globalThis.structuredClone = function structuredClone(value) {
        \\    if (value === null || typeof value !== 'object') return value;
        \\    if (value instanceof Date)   return new Date(value.getTime());
        \\    if (value instanceof RegExp) return new RegExp(value.source, value.flags);
        \\    if (value instanceof Map) {
        \\      var m = new Map();
        \\      value.forEach(function (v, k) { m.set(structuredClone(k), structuredClone(v)); });
        \\      return m;
        \\    }
        \\    if (value instanceof Set) {
        \\      var s = new Set();
        \\      value.forEach(function (v) { s.add(structuredClone(v)); });
        \\      return s;
        \\    }
        \\    if (Array.isArray(value)) return value.map(structuredClone);
        \\    var out = {};
        \\    for (var k in value) {
        \\      if (Object.prototype.hasOwnProperty.call(value, k)) out[k] = structuredClone(value[k]);
        \\    }
        \\    return out;
        \\  };
        \\})();
    ;
};

// ── QuickJS interrupt handler ────────────────────────────────────────────
//
// QuickJS calls this handler periodically (~every 10k bytecode ops) during
// JS execution. Returning true aborts execution with InternalError, which
// propagates back through `JS_Eval` / `JS_Call` as a normal JS exception.
// AWR's runInlineScript / runExternalScript catch this exception silently
// (via `js.eval(...) catch {}`), so a deadline-killed script behaves like
// any other parse-or-throw script: subsequent navigation continues.
//
// Cadence is bytecode-counter based, NOT wall-clock. Sufficient for the
// gtag.js infinite-loop class of hang (handler fires every few microseconds
// inside a tight loop). A stuck native callback is NOT caught — but AWR's
// host functions (console, fetch shim, setTimeout) are non-blocking on
// the synchronous path.
fn evalDeadlineHandler(deadline_ptr: ?*i64, _: *qjs.Runtime) bool {
    const deadline = deadline_ptr orelse return false;
    if (deadline.* == 0) return false; // unbounded mode
    return wallClockMillis() >= deadline.*;
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "JsEngine.init and deinit" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();
}

test "JsEngine.eval — basic arithmetic" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    try engine.eval("const x = 1 + 2;", "<test>");
    const ok = try engine.evalBool("x === 3");
    try std.testing.expect(ok);
}

test "JsEngine.eval — exception returns error" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const result = engine.eval("throw new Error('boom');", "<test>");
    try std.testing.expectError(JsError.EvalException, result);
}

test "JsEngine.eval — undefined variable throws" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const result = engine.eval("notDefined + 1;", "<test>");
    try std.testing.expectError(JsError.EvalException, result);
}

test "JsEngine — console.log is defined" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("typeof console.log === 'function'");
    try std.testing.expect(ok);
}

test "JsEngine — console.warn is defined" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("typeof console.warn === 'function'");
    try std.testing.expect(ok);
}

test "JsEngine — console.error is defined" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("typeof console.error === 'function'");
    try std.testing.expect(ok);
}

test "JsEngine — console.log does not throw" {
    const Sink = struct {
        fn write(_: *anyopaque, _: ConsoleSink.Level, _: []const u8) void {}
    };
    const sink = ConsoleSink{ .ptr = @ptrFromInt(1), .writeFn = Sink.write };
    var engine = try JsEngine.init(std.testing.allocator, sink);
    defer engine.deinit();

    try engine.eval("console.log('hello from test');", "<test>");
}

test "JsEngine — setTimeout is defined and returns a number" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("typeof setTimeout === 'function'");
    try std.testing.expect(ok);
    // Without an attached EventLoop the timer returns 0 (not scheduled) but
    // must still be a number so page scripts don't throw.
    const id_ok = try engine.evalBool("typeof setTimeout(function(){}, 100) === 'number'");
    try std.testing.expect(id_ok);
}

test "JsEngine — clearTimeout is defined" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("typeof clearTimeout === 'function'");
    try std.testing.expect(ok);
}

test "JsEngine — setInterval is defined" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("typeof setInterval === 'function'");
    try std.testing.expect(ok);
}

test "JsEngine — clearInterval is defined" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("typeof clearInterval === 'function'");
    try std.testing.expect(ok);
}

test "JsEngine — fetch is a function" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("typeof fetch === 'function'");
    try std.testing.expect(ok);
}

test "JsEngine — fetch returns a Promise (rejects when no host)" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("fetch('https://example.com') instanceof Promise");
    try std.testing.expect(ok);
}

test "JsEngine — structuredClone is defined" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    try engine.eval(
        \\const original = { a: 1, nested: { b: [1, 2, 3] } };
        \\const clone    = structuredClone(original);
        \\original.a = 99;
        \\original.nested.b.push(4);
    , "<test>");
    const a_ok = try engine.evalBool("clone.a === 1");
    const b_ok = try engine.evalBool("clone.nested.b.length === 3");
    try std.testing.expect(a_ok);
    try std.testing.expect(b_ok);
}

test "JsEngine — Promise basics work" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    try engine.eval(
        \\let resolved = false;
        \\Promise.resolve(42).then(v => { resolved = (v === 42); });
    , "<test>");
    engine.drainMicrotasks();
    const ok = try engine.evalBool("resolved");
    try std.testing.expect(ok);
}

test "JsEngine — drainMicrotasks resolves chained promises" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    try engine.eval(
        \\let result = 0;
        \\Promise.resolve(1)
        \\  .then(v => v + 1)
        \\  .then(v => v + 1)
        \\  .then(v => { result = v; });
    , "<test>");
    engine.drainMicrotasks();
    const ok = try engine.evalBool("result === 3");
    try std.testing.expect(ok);
}

test "JsEngine — JSON is available" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("JSON.parse('{\"a\":1}').a === 1");
    try std.testing.expect(ok);
}

test "JsEngine — Array.from works" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("Array.from({length:3}, (_,i) => i).join(',') === '0,1,2'");
    try std.testing.expect(ok);
}

test "JsEngine — custom ConsoleSink captures output" {
    const Capture = struct {
        buf: [256]u8 = undefined,
        len: usize = 0,

        fn write(ptr: *anyopaque, _: ConsoleSink.Level, msg: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const n = @min(msg.len, self.buf.len);
            @memcpy(self.buf[0..n], msg[0..n]);
            self.len = n;
        }
    };

    var cap = Capture{};
    const sink = ConsoleSink{
        .ptr = &cap,
        .writeFn = Capture.write,
    };

    var engine = try JsEngine.init(std.testing.allocator, sink);
    defer engine.deinit();

    try engine.eval("console.log('hello sink');", "<test>");
    try std.testing.expectEqualStrings("hello sink", cap.buf[0..cap.len]);
}

test "JsEngine — console.log object is serialized as JSON" {
    const Capture = struct {
        buf: [256]u8 = undefined,
        len: usize = 0,
        fn write(ptr: *anyopaque, _: ConsoleSink.Level, msg: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const n = @min(msg.len, self.buf.len);
            @memcpy(self.buf[0..n], msg[0..n]);
            self.len = n;
        }
    };
    var cap = Capture{};
    const sink = ConsoleSink{ .ptr = &cap, .writeFn = Capture.write };
    var eng = try JsEngine.init(std.testing.allocator, sink);
    defer eng.deinit();
    // Execute inline JS that logs an object
    const js_inject = JsEngine.eval;
    js_inject(&eng, "console.log({a: 1, b: 2});", "<test>") catch {};
    // Should contain "a" and "1", not "[object]"
    try std.testing.expect(std.mem.indexOf(u8, cap.buf[0..cap.len], "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf[0..cap.len], "[object]") == null);
}

test "JsEngine — setGlobal exposes value to JS" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const val = qjs.Value.initInt32(99);
    defer val.deinit(engine.ctx);
    try engine.setGlobal("__testProp__", val.dup(engine.ctx));

    const ok = try engine.evalBool("__testProp__ === 99");
    try std.testing.expect(ok);
}

test "JsEngine.evalString — string concatenation" {
    var eng = try JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    const result = try eng.evalString("'hello ' + 'world'");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}
test "JsEngine.evalString — number to string" {
    var eng = try JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    const result = try eng.evalString("String(42)");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("42", result);
}
test "JsEngine.evalString — exception returns error" {
    var eng = try JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try std.testing.expectError(error.EvalException, eng.evalString("throw new Error('x')"));
}

test "JsEngine — eval deadline aborts infinite loop" {
    // B2 regression test: without the interrupt handler, QuickJS would
    // run the while(true) loop forever. With the deadline-aware handler
    // installed at JsEngine.init, eval must throw an exception and return
    // within ~2x the budget on a tight loop.
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    engine.setEvalDeadlineMs(50);
    defer engine.clearEvalDeadline();

    const start_ms = wallClockMillis();
    // The catch swallows the exception (matches runInlineScript pattern).
    engine.eval("while(true){}", "<deadline-test>") catch {};
    const elapsed_ms = wallClockMillis() - start_ms;

    // Must NOT have run forever. CI-tolerant upper bound: 1s for a 50ms
    // budget is generous (QuickJS poll cadence on slow runners can stretch
    // a few hundred ms). MUST be much less than 60s (the gtag.js repro time).
    try std.testing.expect(elapsed_ms < 1_000);
}

test "JsEngine — clearEvalDeadline restores unbounded mode" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    engine.setEvalDeadlineMs(50);
    engine.clearEvalDeadline();
    // Now eval should NOT be interrupted by the prior deadline. A
    // short script must complete normally.
    try engine.eval("var x = 1 + 1;", "<post-clear>");
}

test "JsEngine — matchMedia returns MediaQueryList stub" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();
    // matchMedia must be callable as a function returning an object whose
    // shape matches feature-detection expectations.
    try std.testing.expect(try engine.evalBool("typeof matchMedia === 'function'"));
    try std.testing.expect(try engine.evalBool("typeof matchMedia('(prefers-color-scheme: dark)') === 'object'"));
    try std.testing.expect(try engine.evalBool("matchMedia('(prefers-color-scheme: dark)').matches === false"));
    try std.testing.expect(try engine.evalBool("matchMedia('').media === ''"));
    try std.testing.expect(try engine.evalBool("matchMedia('(min-width: 600px)').media === '(min-width: 600px)'"));
    // addEventListener / addListener / dispatchEvent must be callable
    // without throwing — typical theme-detection pattern.
    try std.testing.expect(try engine.evalBool(
        "var q = matchMedia('(min-width: 1px)'); q.addEventListener('change', function(){}); q.removeEventListener('change', function(){}); q.addListener(function(){}); q.dispatchEvent(new Object()) === false"));
}
