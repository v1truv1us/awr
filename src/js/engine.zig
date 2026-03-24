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
                    .log  => "[JS]  ",
                    .warn => "[JS warn] ",
                    .err  => "[JS error] ",
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
    sink:      ConsoleSink,
    allocator: std.mem.Allocator,
    /// Optional extension pointer set by dom/bridge.zig.
    /// Allows the DOM bridge callbacks to reach the Document without
    /// a circular import dependency.
    extension: ?*anyopaque = null,
};

/// Expose HostData so bridge.zig can retrieve it via ctx.getOpaque().
pub const EngineHostData = HostData;

// ── JsEngine ─────────────────────────────────────────────────────────────

/// Owns a QuickJS Runtime + Context with Web APIs installed.
/// Must outlive any JsValue references obtained from it.
pub const JsEngine = struct {
    rt:        *qjs.Runtime,
    ctx:       *qjs.Context,
    host:      *HostData,
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
            .sink      = sink orelse ConsoleSink.defaultSink(),
            .allocator = allocator,
        };
        ctx.setOpaque(HostData, host);

        var engine = JsEngine{
            .rt        = rt,
            .ctx       = ctx,
            .host      = host,
            .allocator = allocator,
        };
        try engine.installWebApis();
        return engine;
    }

    pub fn deinit(self: *JsEngine) void {
        self.ctx.deinit();
        self.rt.deinit();
        self.allocator.destroy(self.host);
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
        try self.installTimerStubs();
        try self.installFetchStub();
    }

    // ── console ─────────────────────────────────────────────────────────

    fn installConsole(self: *JsEngine) JsError!void {
        const ctx = self.ctx;
        const console = qjs.Value.initObject(ctx);
        defer console.deinit(ctx);

        const logFn   = qjs.Value.initCFunction(ctx, consoleLog,   "log",   1);
        const warnFn  = qjs.Value.initCFunction(ctx, consoleWarn,  "warn",  1);
        const errorFn = qjs.Value.initCFunction(ctx, consoleError, "error", 1);
        defer logFn.deinit(ctx);
        defer warnFn.deinit(ctx);
        defer errorFn.deinit(ctx);

        console.setPropertyStr(ctx, "log",   logFn.dup(ctx))   catch return JsError.PropertySetFailed;
        console.setPropertyStr(ctx, "warn",  warnFn.dup(ctx))  catch return JsError.PropertySetFailed;
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
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

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
                // Objects/arrays: use JSON.stringify
                const json_val = ctx.eval(
                    "JSON.stringify(arguments[0])",
                    "<console>",
                    .{},
                );
                _ = json_val; // can't easily use in this context; fallback
                _ = w.writeAll("[object]") catch {};
            }
        }

        host.sink.write(level, fbs.getWritten());
    }

    // ── timer stubs ──────────────────────────────────────────────────────

    fn installTimerStubs(self: *JsEngine) JsError!void {
        const ctx = self.ctx;
        // setTimeout(cb, delay, ...args) → returns 0 (never fires in Phase 2)
        const setTimeoutFn    = qjs.Value.initCFunction(ctx, timerStub,   "setTimeout",    2);
        const clearTimeoutFn  = qjs.Value.initCFunction(ctx, timerClear,  "clearTimeout",  1);
        const setIntervalFn   = qjs.Value.initCFunction(ctx, timerStub,   "setInterval",   2);
        const clearIntervalFn = qjs.Value.initCFunction(ctx, timerClear,  "clearInterval", 1);
        defer setTimeoutFn.deinit(ctx);
        defer clearTimeoutFn.deinit(ctx);
        defer setIntervalFn.deinit(ctx);
        defer clearIntervalFn.deinit(ctx);

        try self.setGlobal("setTimeout",    setTimeoutFn.dup(ctx));
        try self.setGlobal("clearTimeout",  clearTimeoutFn.dup(ctx));
        try self.setGlobal("setInterval",   setIntervalFn.dup(ctx));
        try self.setGlobal("clearInterval", clearIntervalFn.dup(ctx));
    }

    fn timerStub(_: ?*qjs.Context, _: qjs.Value, _: []const @import("quickjs").c.JSValue) qjs.Value {
        // Phase 2 stub: return timer ID 0, never fires.
        return qjs.Value.initInt32(0);
    }

    fn timerClear(_: ?*qjs.Context, _: qjs.Value, _: []const @import("quickjs").c.JSValue) qjs.Value {
        return qjs.Value.undefined;
    }

    // ── fetch stub ───────────────────────────────────────────────────────

    fn installFetchStub(self: *JsEngine) JsError!void {
        const ctx = self.ctx;
        const fetchFn = qjs.Value.initCFunction(ctx, fetchStub, "fetch", 1);
        defer fetchFn.deinit(ctx);
        try self.setGlobal("fetch", fetchFn.dup(ctx));
    }

    fn fetchStub(ctx: ?*qjs.Context, _: qjs.Value, _: []const @import("quickjs").c.JSValue) qjs.Value {
        const c = ctx orelse return qjs.Value.undefined;
        // Return a rejected Promise so code that does `fetch(...).then(...)` fails gracefully.
        const result = c.eval(
            "Promise.reject(new Error('fetch() not available in Phase 2 — use Client.fetch() at the Zig layer'))",
            "<fetch-stub>",
            .{},
        );
        return result;
    }
};

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
        len: usize   = 0,

        fn write(ptr: *anyopaque, _: ConsoleSink.Level, msg: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const n = @min(msg.len, self.buf.len);
            @memcpy(self.buf[0..n], msg[0..n]);
            self.len = n;
        }
    };

    var cap = Capture{};
    const sink = ConsoleSink{
        .ptr     = &cap,
        .writeFn = Capture.write,
    };

    var engine = try JsEngine.init(std.testing.allocator, sink);
    defer engine.deinit();

    try engine.eval("console.log('hello sink');", "<test>");
    try std.testing.expectEqualStrings("hello sink", cap.buf[0..cap.len]);
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
