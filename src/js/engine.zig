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

pub const FetchResponse = struct {
    status: u16,
    body: []u8,
};

pub const FetchHandler = *const fn (
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    url: []const u8,
) anyerror!FetchResponse;

pub const CookieGetHandler = *const fn (
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
) anyerror![]u8;

pub const CookieSetHandler = *const fn (
    ptr: *anyopaque,
    value: []const u8,
) anyerror!void;

const TimerTask = struct {
    id: i32,
    callback: qjs.Value,
    is_string: bool,
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
    next_timer_id: i32 = 1,
    timers: std.ArrayListUnmanaged(TimerTask) = .empty,
    fetch_ctx: ?*anyopaque = null,
    fetch_fn: ?FetchHandler = null,
    cookie_ctx: ?*anyopaque = null,
    cookie_get_fn: ?CookieGetHandler = null,
    cookie_set_fn: ?CookieSetHandler = null,
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

    /// Create a new JsEngine.
    /// `sink` defaults to stderr if null.
    pub fn init(allocator: std.mem.Allocator, sink: ?ConsoleSink) JsError!JsEngine {
        const rt = qjs.Runtime.init() catch return JsError.RuntimeInitFailed;
        errdefer rt.deinit();

        rt.setMaxStackSize(4 * 1024 * 1024); // 4 MB

        const ctx = qjs.Context.init(rt) catch return JsError.ContextInitFailed;
        errdefer ctx.deinit();

        // Allocate host data and store in context opaque so callbacks can reach it.
        const host = allocator.create(HostData) catch return JsError.OutOfMemory;
        errdefer allocator.destroy(host);
        host.* = .{
            .sink = sink orelse ConsoleSink.defaultSink(),
            .allocator = allocator,
        };
        ctx.setOpaque(HostData, host);

        var engine = JsEngine{
            .rt = rt,
            .ctx = ctx,
            .host = host,
            .allocator = allocator,
        };
        try engine.installWebApis();
        return engine;
    }

    pub fn deinit(self: *JsEngine) void {
        self.clearTimers();
        self.ctx.deinit();
        self.rt.deinit();
        self.allocator.destroy(self.host);
    }

    // ── Evaluation ──────────────────────────────────────────────────────

    fn evalValue(self: *JsEngine, source: []const u8, filename: [:0]const u8) JsError!qjs.Value {
        const zsrc = self.allocator.allocSentinel(u8, source.len, 0) catch return JsError.OutOfMemory;
        defer self.allocator.free(zsrc);
        @memcpy(zsrc[0..source.len], source);

        const result = self.ctx.eval(zsrc[0..source.len], filename, .{});
        if (result.isException()) {
            result.deinit(self.ctx);
            return JsError.EvalException;
        }
        return result;
    }

    /// Evaluate a JS source string.
    /// Returns JsError.EvalException on any JS exception.
    pub fn eval(self: *JsEngine, source: []const u8, filename: [:0]const u8) JsError!void {
        const result = try self.evalValue(source, filename);
        defer result.deinit(self.ctx);
    }

    /// Evaluate and return a boolean result.
    /// Caller must ensure the expression yields a boolean.
    pub fn evalBool(self: *JsEngine, source: []const u8) JsError!bool {
        const result = try self.evalValue(source, "<eval>");
        defer result.deinit(self.ctx);
        return result.toBool(self.ctx) catch false;
    }

    /// Evaluate and return a heap-allocated string result.
    /// Caller owns the returned slice and must free it.
    pub fn evalString(self: *JsEngine, source: []const u8) JsError![]u8 {
        const val = try self.evalValue(source, "<eval>");
        defer val.deinit(self.ctx);
        const cstr = val.toCString(self.ctx) orelse return JsError.OutOfMemory;
        defer self.ctx.freeCString(cstr);
        return self.allocator.dupe(u8, std.mem.span(cstr));
    }

    /// Drain the microtask / Promise job queue.
    pub fn drainMicrotasks(self: *JsEngine) void {
        while (true) {
            var progressed = false;
            while (self.rt.isJobPending()) {
                _ = self.rt.executePendingJob() catch break;
                progressed = true;
            }
            const ran_timers = self.evalBool(
                "typeof __awrDrainTimers === 'function' && __awrDrainTimers() > 0",
            ) catch false;
            if (ran_timers) progressed = true;
            if (!progressed) break;
        }
    }

    pub fn setFetchHandler(self: *JsEngine, ctx_ptr: *anyopaque, fetch_fn: FetchHandler) void {
        self.host.fetch_ctx = ctx_ptr;
        self.host.fetch_fn = fetch_fn;
    }

    pub fn clearFetchHandler(self: *JsEngine) void {
        self.host.fetch_ctx = null;
        self.host.fetch_fn = null;
    }

    pub fn setCookieHandler(self: *JsEngine, ctx_ptr: *anyopaque, get_fn: CookieGetHandler, set_fn: CookieSetHandler) void {
        self.host.cookie_ctx = ctx_ptr;
        self.host.cookie_get_fn = get_fn;
        self.host.cookie_set_fn = set_fn;
    }

    pub fn clearCookieHandler(self: *JsEngine) void {
        self.host.cookie_ctx = null;
        self.host.cookie_get_fn = null;
        self.host.cookie_set_fn = null;
    }

    fn clearTimers(self: *JsEngine) void {
        for (self.host.timers.items) |*task| {
            task.callback.deinit(self.ctx);
        }
        self.host.timers.deinit(self.allocator);
    }

    fn runTimers(self: *JsEngine) bool {
        var ran = false;
        while (self.host.timers.items.len > 0) {
            ran = true;
            const task = self.host.timers.swapRemove(0);
            defer task.callback.deinit(self.ctx);

            if (task.is_string) {
                const cstr = task.callback.toCString(self.ctx) orelse continue;
                defer self.ctx.freeCString(cstr);
                _ = self.ctx.eval(std.mem.span(cstr), "<timer>", .{});
            } else {
                const result = task.callback.call(self.ctx, qjs.Value.undefined, &.{});
                defer result.deinit(self.ctx);
            }
        }
        return ran;
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
        try self.installTimerStubs();
        try self.installFetchStub();
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
        var fbs = std.Io.Writer.fixed(&buf);
        const w = &fbs;

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

        host.sink.write(level, fbs.buffered());
    }

    // ── timer stubs ──────────────────────────────────────────────────────

    fn installTimerStubs(self: *JsEngine) JsError!void {
        try self.eval(
            \\globalThis.__awrNextTimerId = 1;
            \\globalThis.setTimeout = function(cb, delay) {
            \\  const id = globalThis.__awrNextTimerId++;
            \\  if (typeof cb === 'function') cb();
            \\  else eval(String(cb));
            \\  return id;
            \\};
            \\globalThis.clearTimeout = function(id) {};
            \\globalThis.setInterval = function(cb, delay) {
            \\  return globalThis.setTimeout(cb, delay);
            \\};
            \\globalThis.clearInterval = globalThis.clearTimeout;
        , "<timer-polyfill>");
    }

    fn timerStub(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
        const c = ctx orelse return qjs.Value.initInt32(0);
        const host = c.getOpaque(HostData) orelse return qjs.Value.initInt32(0);
        if (args.len == 0) return qjs.Value.initInt32(0);

        const callback = qjs.Value.fromCVal(args[0]);
        const id = host.next_timer_id;
        host.next_timer_id += 1;
        host.timers.append(host.allocator, .{
            .id = id,
            .callback = callback.dup(c),
            .is_string = callback.isString(),
        }) catch return qjs.Value.exception;
        return qjs.Value.initInt32(id);
    }

    fn timerClear(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
        const c = ctx orelse return qjs.Value.undefined;
        const host = c.getOpaque(HostData) orelse return qjs.Value.undefined;
        if (args.len == 0) return qjs.Value.undefined;

        const id_val = qjs.Value.fromCVal(args[0]);
        const id = id_val.toInt32(c) catch return qjs.Value.undefined;
        var i: usize = 0;
        while (i < host.timers.items.len) : (i += 1) {
            if (host.timers.items[i].id == id) {
                var task = host.timers.swapRemove(i);
                task.callback.deinit(c);
                break;
            }
        }
        return qjs.Value.undefined;
    }

    // ── fetch stub ───────────────────────────────────────────────────────

    fn installFetchStub(self: *JsEngine) JsError!void {
        const ctx = self.ctx;
        const fetchFn = qjs.Value.initCFunction(ctx, fetchStub, "fetch", 1);
        defer fetchFn.deinit(ctx);
        try self.setGlobal("fetch", fetchFn.dup(ctx));
    }

    fn fetchStub(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
        const c = ctx orelse return qjs.Value.undefined;
        const host = c.getOpaque(HostData) orelse
            return c.eval(
                "Promise.reject(new Error('fetch() not available in Phase 2 — use Client.fetch() at the Zig layer'))",
                "<fetch-stub>",
                .{},
            );
        if (host.fetch_ctx == null or host.fetch_fn == null or args.len == 0) {
            return c.eval(
                "Promise.reject(new Error('fetch() not available in Phase 2 — use Client.fetch() at the Zig layer'))",
                "<fetch-stub>",
                .{},
            );
        }

        const url_val = qjs.Value.fromCVal(args[0]);
        const cstr = url_val.toCString(c) orelse return c.eval(
            "Promise.reject(new Error('fetch() argument must be a string'))",
            "<fetch-stub>",
            .{},
        );
        defer c.freeCString(cstr);

        const fetched = host.fetch_fn.?(host.fetch_ctx.?, host.allocator, std.mem.span(cstr)) catch {
            return c.eval(
                "Promise.reject(new Error('fetch() failed'))",
                "<fetch-stub>",
                .{},
            );
        };
        defer host.allocator.free(fetched.body);

        var script: std.ArrayList(u8) = .empty;
        defer script.deinit(host.allocator);

        script.appendSlice(host.allocator, "Promise.resolve({status:") catch return qjs.Value.exception;
        const status_str = std.fmt.allocPrint(host.allocator, "{d}", .{fetched.status}) catch return qjs.Value.exception;
        defer host.allocator.free(status_str);
        script.appendSlice(host.allocator, status_str) catch return qjs.Value.exception;
        script.appendSlice(host.allocator, ",ok:") catch return qjs.Value.exception;
        script.appendSlice(host.allocator, if (fetched.status >= 200 and fetched.status < 300) "true" else "false") catch return qjs.Value.exception;
        script.appendSlice(host.allocator, ",text:function(){return Promise.resolve(") catch return qjs.Value.exception;
        appendJsStr(&script, host.allocator, fetched.body) catch return qjs.Value.exception;
        script.appendSlice(host.allocator, ");},json:function(){return Promise.resolve(JSON.parse(") catch return qjs.Value.exception;
        appendJsStr(&script, host.allocator, fetched.body) catch return qjs.Value.exception;
        script.appendSlice(host.allocator, "));}})") catch return qjs.Value.exception;
        script.append(host.allocator, 0) catch return qjs.Value.exception;

        return c.eval(script.items[0 .. script.items.len - 1], "<fetch-native>", .{});
    }
};

fn appendJsStr(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try list.append(alloc, '\'');
    for (s) |c| {
        switch (c) {
            '\'' => try list.appendSlice(alloc, "\\'"),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => try list.append(alloc, c),
        }
    }
    try list.append(alloc, '\'');
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
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    try engine.eval("console.log('hello from test');", "<test>");
}

test "JsEngine — setTimeout is defined and returns a number" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("typeof setTimeout === 'function'");
    try std.testing.expect(ok);
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

test "JsEngine — fetch is a function (stub)" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("typeof fetch === 'function'");
    try std.testing.expect(ok);
}

test "JsEngine — fetch stub returns a Promise" {
    var engine = try JsEngine.init(std.testing.allocator, null);
    defer engine.deinit();

    const ok = try engine.evalBool("fetch('https://example.com') instanceof Promise");
    try std.testing.expect(ok);
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
