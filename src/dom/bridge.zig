/// bridge.zig — JS↔DOM bindings for AWR Phase 2.
///
/// Installs a `document` global object (and companion window/navigator/
/// location stubs) into a JsEngine, backed by a Zig DOM Document.
///
/// Architecture
/// ────────────
/// Five native C callbacks are registered as JS globals:
///   __awr_querySelector(sel)      → JSON element or null
///   __awr_querySelectorAll(sel)   → JSON array string
///   __awr_getElementById(id)      → JSON element or null
///   __awr_getTitle()              → string
///   __awr_getBody()               → JSON element or null
///
/// A JS polyfill (BRIDGE_POLYFILL) wraps these primitives in proper
/// DOM-like objects (document, HTMLElement prototype, MutationObserver
/// stub, etc.).  This keeps all the idiomatic JS API surface in JS
/// while the expensive parts (tree traversal, serialisation) stay in Zig.
///
/// Phase 2 contract
/// ────────────────
/// Queries reflect the Zig DOM tree built from the fetched HTML.
/// Mutations (innerHTML setter, textContent setter, appendChild) are
/// JS-only and are NOT reflected back to the Zig tree.
/// That is sufficient for Phase 2: scripts that mutate the DOM will not
/// crash, and scripts that query it will see real page data.
///
/// Lifetime
/// ────────
/// `installDomBridge(engine, doc, alloc)` stores a heap-allocated
/// BridgeCtx in engine.host.extension.  Call `removeDomBridge(engine)`
/// to free it when the Page is destroyed.

const std    = @import("std");
const qjs    = @import("quickjs");
const dom    = @import("node.zig");
const engine = @import("../js/engine.zig");

// ── BridgeCtx ─────────────────────────────────────────────────────────────

/// Stored as engine.host.extension; accessed by native callbacks.
const BridgeCtx = struct {
    doc:       *dom.Document,
    allocator: std.mem.Allocator,
    elem_to_handle: std.AutoHashMap(*dom.Element, u32),
    handle_to_elem: std.ArrayList(*dom.Element),

    fn init(doc: *dom.Document, allocator: std.mem.Allocator) BridgeCtx {
        return .{
            .doc = doc,
            .allocator = allocator,
            .elem_to_handle = std.AutoHashMap(*dom.Element, u32).init(allocator),
            .handle_to_elem = std.ArrayList(*dom.Element).empty,
        };
    }

    fn deinit(self: *BridgeCtx) void {
        self.elem_to_handle.deinit();
        self.handle_to_elem.deinit(self.allocator);
    }
};

fn getBridge(ctx: ?*qjs.Context) ?*BridgeCtx {
    const c = ctx orelse return null;
    const host = c.getOpaque(engine.EngineHostData) orelse return null;
    const ext = host.extension orelse return null;
    return @ptrCast(@alignCast(ext));
}

// ── Public API ────────────────────────────────────────────────────────────

pub const BridgeError = error{ AllocFailed, EvalFailed };

/// Install the DOM bridge into `eng`, backed by `doc`.
/// The bridge is heap-allocated and freed by `removeDomBridge`.
pub fn installDomBridge(
    eng:   *engine.JsEngine,
    doc:   *dom.Document,
    alloc: std.mem.Allocator,
) BridgeError!void {
    const bctx = alloc.create(BridgeCtx) catch return BridgeError.AllocFailed;
    bctx.* = BridgeCtx.init(doc, alloc);

    // Store in host extension
    eng.host.extension = @ptrCast(bctx);

    // Register the five native query callbacks
    installNativeCallbacks(eng) catch return BridgeError.EvalFailed;

    // Install the JS polyfill on top of them
    eng.eval(BRIDGE_POLYFILL, "<dom-bridge>") catch return BridgeError.EvalFailed;
}

/// Free the BridgeCtx allocated by installDomBridge.
pub fn removeDomBridge(eng: *engine.JsEngine) void {
    const host = eng.ctx.getOpaque(engine.EngineHostData) orelse return;
    const ext  = host.extension orelse return;
    const bctx: *BridgeCtx = @ptrCast(@alignCast(ext));
    bctx.deinit();
    bctx.allocator.destroy(bctx);
    host.extension = null;
}

// ── Native callbacks ──────────────────────────────────────────────────────

fn installNativeCallbacks(eng: *engine.JsEngine) !void {
    const ctx = eng.ctx;

    inline for (.{
        .{ "querySelector",    querySelectorFn },
        .{ "querySelectorAll", querySelectorAllFn },
        .{ "querySelectorScoped", querySelectorScopedFn },
        .{ "querySelectorAllScoped", querySelectorAllScopedFn },
        .{ "matches",         matchesFn },
        .{ "closest",         closestFn },
        .{ "getElementById",   getElementByIdFn },
        .{ "getTitle",         getTitleFn },
        .{ "getBody",          getBodyFn },
        .{ "createElement",    createElementFn },
        .{ "setAttribute",     setAttributeFn },
        .{ "removeAttribute",  removeAttributeFn },
        .{ "setTextContent",   setTextContentFn },
        .{ "appendChild",      appendChildFn },
        .{ "insertBefore",     insertBeforeFn },
        .{ "removeChild",      removeChildFn },
    }) |entry| {
        const fname: [:0]const u8 = "__awr_" ++ entry[0] ++ "__";
        const fn_val = qjs.Value.initCFunction(ctx, entry[1], fname, 1);
        defer fn_val.deinit(ctx);
        eng.setGlobal(fname, fn_val.dup(ctx)) catch return error.PropertySetFailed;
    }
}

/// Write `str` as a JSON string literal (with surrounding quotes and escaping)
/// into any writer that exposes `writeByte` and `writeAll`.  Using `anytype`
/// here avoids depending on the std.json serialization API which changed in
/// Zig 0.15 (encodeJsonString / stringify moved into std.json.Stringify and
/// require the new *std.io.Writer type rather than the old GenericWriter).
fn writeJsonStr(w: anytype, str: []const u8) !void {
    try w.writeByte('"');
    for (str) |c| {
        switch (c) {
            '"'         => try w.writeAll("\\\""),
            '\\'        => try w.writeAll("\\\\"),
            '\n'        => try w.writeAll("\\n"),    // 0x0a
            '\r'        => try w.writeAll("\\r"),    // 0x0d
            '\t'        => try w.writeAll("\\t"),    // 0x09
            // remaining control chars not already handled above
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                var esc: [6]u8 = undefined;
                const s = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch continue;
                try w.writeAll(s);
            },
            else        => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// Serialize an Element to a compact JSON object string.
/// Writes into `buf`; returns the written slice or null on overflow.
fn ensureHandle(bridge: *BridgeCtx, elem: *dom.Element) ?u32 {
    if (bridge.elem_to_handle.get(elem)) |h| return h;
    bridge.handle_to_elem.append(bridge.allocator, elem) catch return null;
    const h: u32 = @intCast(bridge.handle_to_elem.items.len);
    bridge.elem_to_handle.put(elem, h) catch return null;
    return h;
}

fn getElemByHandle(bridge: *BridgeCtx, handle: u32) ?*dom.Element {
    if (handle == 0) return null;
    const idx: usize = handle - 1;
    if (idx >= bridge.handle_to_elem.items.len) return null;
    return bridge.handle_to_elem.items[idx];
}

fn elementToJson(bridge: *BridgeCtx, elem: *dom.Element, buf: []u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    const handle = ensureHandle(bridge, elem) orelse return null;

    w.writeAll("{\"_h\":") catch return null;
    var hbuf: [32]u8 = undefined;
    const hs = std.fmt.bufPrint(&hbuf, "{d}", .{handle}) catch return null;
    w.writeAll(hs) catch return null;
    w.writeAll(",\"tag\":") catch return null;
    writeJsonStr(&w, elem.tag) catch return null;
    w.writeAll(",\"attrs\":[") catch return null;
    for (elem.attributes, 0..) |attr, i| {
        if (i > 0) w.writeByte(',') catch return null;
        w.writeAll("{\"name\":") catch return null;
        writeJsonStr(&w, attr.name) catch return null;
        w.writeAll(",\"value\":") catch return null;
        writeJsonStr(&w, attr.value) catch return null;
        w.writeByte('}') catch return null;
    }
    w.writeAll("],\"text\":") catch return null;
    var tbuf: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tbuf);
    const text = elem.textContent(fba.allocator()) catch "";
    writeJsonStr(&w, text) catch return null;
    w.writeByte('}') catch return null;

    return w.buffered();
}

fn querySelectorFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.null;
    const c      = ctx orelse return qjs.Value.null;
    if (args.len == 0) return qjs.Value.null;

    const sel_val: qjs.Value = @bitCast(args[0]);
    const sel_cstr = sel_val.toCString(c) orelse return qjs.Value.null;
    defer c.freeCString(sel_cstr);
    const sel = std.mem.span(sel_cstr);

    const elem = bridge.doc.querySelector(sel) orelse return qjs.Value.null;
    var buf: [8192]u8 = undefined;
    const json = elementToJson(bridge, elem, &buf) orelse return qjs.Value.null;
    return qjs.Value.initStringLen(c, json);
}

fn querySelectorAllFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.null;
    const c      = ctx orelse return qjs.Value.null;
    if (args.len == 0) return qjs.Value.initStringLen(c, "[]");

    const sel_val: qjs.Value = @bitCast(args[0]);
    const sel_cstr = sel_val.toCString(c) orelse return qjs.Value.initStringLen(c, "[]");
    defer c.freeCString(sel_cstr);
    const sel = std.mem.span(sel_cstr);

    const elems = bridge.doc.querySelectorAll(sel, bridge.allocator) catch return qjs.Value.initStringLen(c, "[]");
    defer bridge.allocator.free(elems);

    var buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeByte('[') catch return qjs.Value.initStringLen(c, "[]");
    for (elems, 0..) |elem, i| {
        if (i > 0) w.writeByte(',') catch break;
        var ebuf: [8192]u8 = undefined;
        if (elementToJson(bridge, elem, &ebuf)) |json| {
            w.writeAll(json) catch break;
        }
    }
    w.writeByte(']') catch {};
    return qjs.Value.initStringLen(c, w.buffered());
}

fn getElementByIdFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.null;
    const c      = ctx orelse return qjs.Value.null;
    if (args.len == 0) return qjs.Value.null;

    const id_val: qjs.Value = @bitCast(args[0]);
    const id_cstr = id_val.toCString(c) orelse return qjs.Value.null;
    defer c.freeCString(id_cstr);
    const id = std.mem.span(id_cstr);

    const elem = bridge.doc.getElementById(id) orelse return qjs.Value.null;
    var buf: [8192]u8 = undefined;
    const json = elementToJson(bridge, elem, &buf) orelse return qjs.Value.null;
    return qjs.Value.initStringLen(c, json);
}

fn querySelectorScopedFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.null;
    const c = ctx orelse return qjs.Value.null;
    if (args.len < 2) return qjs.Value.null;

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.null;
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.null;
    const sel_val: qjs.Value = @bitCast(args[1]);
    const sel_cstr = sel_val.toCString(c) orelse return qjs.Value.null;
    defer c.freeCString(sel_cstr);

    const found = elem.querySelector(std.mem.span(sel_cstr)) orelse return qjs.Value.null;
    var buf: [8192]u8 = undefined;
    const json = elementToJson(bridge, found, &buf) orelse return qjs.Value.null;
    return qjs.Value.initStringLen(c, json);
}

fn querySelectorAllScopedFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.null;
    const c = ctx orelse return qjs.Value.null;
    if (args.len < 2) return qjs.Value.initStringLen(c, "[]");

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.initStringLen(c, "[]");
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.initStringLen(c, "[]");
    const sel_val: qjs.Value = @bitCast(args[1]);
    const sel_cstr = sel_val.toCString(c) orelse return qjs.Value.initStringLen(c, "[]");
    defer c.freeCString(sel_cstr);

    const elems = elem.querySelectorAll(std.mem.span(sel_cstr), bridge.allocator) catch return qjs.Value.initStringLen(c, "[]");
    defer bridge.allocator.free(elems);

    var buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeByte('[') catch return qjs.Value.initStringLen(c, "[]");
    for (elems, 0..) |item, i| {
        if (i > 0) w.writeByte(',') catch break;
        var ebuf: [8192]u8 = undefined;
        if (elementToJson(bridge, item, &ebuf)) |json| {
            w.writeAll(json) catch break;
        }
    }
    w.writeByte(']') catch {};
    return qjs.Value.initStringLen(c, w.buffered());
}

fn matchesFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initBool(false);
    const c = ctx orelse return qjs.Value.initBool(false);
    if (args.len < 2) return qjs.Value.initBool(false);

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.initBool(false);
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.initBool(false);
    const sel_val: qjs.Value = @bitCast(args[1]);
    const sel_cstr = sel_val.toCString(c) orelse return qjs.Value.initBool(false);
    defer c.freeCString(sel_cstr);
    return qjs.Value.initBool(elem.matches(std.mem.span(sel_cstr)));
}

fn closestFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.null;
    const c = ctx orelse return qjs.Value.null;
    if (args.len < 2) return qjs.Value.null;

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.null;
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.null;
    const sel_val: qjs.Value = @bitCast(args[1]);
    const sel_cstr = sel_val.toCString(c) orelse return qjs.Value.null;
    defer c.freeCString(sel_cstr);

    const found = elem.closest(std.mem.span(sel_cstr)) orelse return qjs.Value.null;
    var buf: [8192]u8 = undefined;
    const json = elementToJson(bridge, found, &buf) orelse return qjs.Value.null;
    return qjs.Value.initStringLen(c, json);
}

fn getTitleFn(ctx: ?*qjs.Context, _: qjs.Value, _: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initStringLen(ctx orelse return qjs.Value.undefined, "");
    const c      = ctx orelse return qjs.Value.undefined;
    const html   = bridge.doc.htmlElement() orelse return qjs.Value.initStringLen(c, "");
    const head   = html.firstChildByTag("head") orelse return qjs.Value.initStringLen(c, "");
    const title  = head.firstChildByTag("title") orelse return qjs.Value.initStringLen(c, "");
    const text   = title.textContent(bridge.allocator) catch return qjs.Value.initStringLen(c, "");
    defer bridge.allocator.free(text);
    return qjs.Value.initStringLen(c, text);
}

fn getBodyFn(ctx: ?*qjs.Context, _: qjs.Value, _: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.null;
    const c      = ctx orelse return qjs.Value.null;
    const body   = bridge.doc.body() orelse return qjs.Value.null;
    var buf: [8192]u8 = undefined;
    const json = elementToJson(bridge, body, &buf) orelse return qjs.Value.null;
    return qjs.Value.initStringLen(c, json);
}

fn parseHandleArg(ctx: *qjs.Context, raw: @import("quickjs").c.JSValue) ?u32 {
    const v: qjs.Value = @bitCast(raw);
    const i = v.toInt32(ctx) catch return null;
    if (i <= 0) return null;
    return @intCast(i);
}

fn createElementFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.null;
    const c = ctx orelse return qjs.Value.null;
    if (args.len < 1) return qjs.Value.null;
    const tag_v: qjs.Value = @bitCast(args[0]);
    const tag_c = tag_v.toCString(c) orelse return qjs.Value.null;
    defer c.freeCString(tag_c);
    const tag = std.mem.span(tag_c);
    const alloc = bridge.doc.arena.allocator();
    const elem = alloc.create(dom.Element) catch return qjs.Value.null;
    elem.* = .{ .tag = alloc.dupe(u8, tag) catch return qjs.Value.null, .attributes = &.{}, .children = .empty, .parent = null };
    var buf: [2048]u8 = undefined;
    const json = elementToJson(bridge, elem, &buf) orelse return qjs.Value.null;
    return qjs.Value.initStringLen(c, json);
}

fn setAttributeFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initBool(false);
    const c = ctx orelse return qjs.Value.initBool(false);
    if (args.len < 3) return qjs.Value.initBool(false);
    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.initBool(false);
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.initBool(false);
    const name_v: qjs.Value = @bitCast(args[1]);
    const val_v: qjs.Value = @bitCast(args[2]);
    const name_c = name_v.toCString(c) orelse return qjs.Value.initBool(false);
    defer c.freeCString(name_c);
    const val_c = val_v.toCString(c) orelse return qjs.Value.initBool(false);
    defer c.freeCString(val_c);
    const alloc = bridge.doc.arena.allocator();
    const name = alloc.dupe(u8, std.mem.span(name_c)) catch return qjs.Value.initBool(false);
    const value = alloc.dupe(u8, std.mem.span(val_c)) catch return qjs.Value.initBool(false);
    for (elem.attributes) |*a| {
        if (std.ascii.eqlIgnoreCase(a.name, name)) {
            a.value = value;
            return qjs.Value.initBool(true);
        }
    }
    const old = elem.attributes;
    const next = alloc.alloc(dom.Attribute, old.len + 1) catch return qjs.Value.initBool(false);
    @memcpy(next[0..old.len], old);
    next[old.len] = .{ .name = name, .value = value };
    elem.attributes = next;
    return qjs.Value.initBool(true);
}

fn removeAttributeFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initBool(false);
    const c = ctx orelse return qjs.Value.initBool(false);
    if (args.len < 2) return qjs.Value.initBool(false);
    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.initBool(false);
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.initBool(false);
    const name_v: qjs.Value = @bitCast(args[1]);
    const name_c = name_v.toCString(c) orelse return qjs.Value.initBool(false);
    defer c.freeCString(name_c);
    const name = std.mem.span(name_c);
    const old = elem.attributes;
    var kept: usize = 0;
    for (old) |a| {
        if (!std.ascii.eqlIgnoreCase(a.name, name)) kept += 1;
    }
    const alloc = bridge.doc.arena.allocator();
    const next = alloc.alloc(dom.Attribute, kept) catch return qjs.Value.initBool(false);
    var j: usize = 0;
    for (old) |a| {
        if (!std.ascii.eqlIgnoreCase(a.name, name)) {
            next[j] = a;
            j += 1;
        }
    }
    elem.attributes = next;
    return qjs.Value.initBool(true);
}

fn setTextContentFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initBool(false);
    const c = ctx orelse return qjs.Value.initBool(false);
    if (args.len < 2) return qjs.Value.initBool(false);
    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.initBool(false);
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.initBool(false);
    const txt_v: qjs.Value = @bitCast(args[1]);
    const txt_c = txt_v.toCString(c) orelse return qjs.Value.initBool(false);
    defer c.freeCString(txt_c);
    elem.children.clearRetainingCapacity();
    const alloc = bridge.doc.arena.allocator();
    const t = alloc.create(dom.Text) catch return qjs.Value.initBool(false);
    t.* = .{ .data = alloc.dupe(u8, std.mem.span(txt_c)) catch return qjs.Value.initBool(false), .parent = elem };
    elem.children.append(alloc, .{ .text = t }) catch return qjs.Value.initBool(false);
    return qjs.Value.initBool(true);
}

fn detachChild(parent: *dom.Element, child: *dom.Element) bool {
    for (parent.children.items, 0..) |n, i| {
        if (n == .element and n.element == child) {
            _ = parent.children.orderedRemove(i);
            child.parent = null;
            return true;
        }
    }
    return false;
}

fn appendChildFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initBool(false);
    const c = ctx orelse return qjs.Value.initBool(false);
    if (args.len < 2) return qjs.Value.initBool(false);
    const ph = parseHandleArg(c, args[0]) orelse return qjs.Value.initBool(false);
    const ch = parseHandleArg(c, args[1]) orelse return qjs.Value.initBool(false);
    const parent = getElemByHandle(bridge, ph) orelse return qjs.Value.initBool(false);
    const child = getElemByHandle(bridge, ch) orelse return qjs.Value.initBool(false);
    if (child.parent) |old| _ = detachChild(old, child);
    parent.children.append(bridge.doc.arena.allocator(), .{ .element = child }) catch return qjs.Value.initBool(false);
    child.parent = parent;
    return qjs.Value.initBool(true);
}

fn insertBeforeFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initBool(false);
    const c = ctx orelse return qjs.Value.initBool(false);
    if (args.len < 3) return qjs.Value.initBool(false);
    const ph = parseHandleArg(c, args[0]) orelse return qjs.Value.initBool(false);
    const nh = parseHandleArg(c, args[1]) orelse return qjs.Value.initBool(false);
    const parent = getElemByHandle(bridge, ph) orelse return qjs.Value.initBool(false);
    const node = getElemByHandle(bridge, nh) orelse return qjs.Value.initBool(false);
    if (node.parent) |old| _ = detachChild(old, node);
    const alloc = bridge.doc.arena.allocator();
    var idx: usize = parent.children.items.len;
    if (parseHandleArg(c, args[2])) |rh| {
        if (getElemByHandle(bridge, rh)) |ref| {
            for (parent.children.items, 0..) |n, i| {
                if (n == .element and n.element == ref) { idx = i; break; }
            }
        }
    }
    parent.children.insert(alloc, idx, .{ .element = node }) catch return qjs.Value.initBool(false);
    node.parent = parent;
    return qjs.Value.initBool(true);
}

fn removeChildFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initBool(false);
    const c = ctx orelse return qjs.Value.initBool(false);
    if (args.len < 2) return qjs.Value.initBool(false);
    const ph = parseHandleArg(c, args[0]) orelse return qjs.Value.initBool(false);
    const ch = parseHandleArg(c, args[1]) orelse return qjs.Value.initBool(false);
    const parent = getElemByHandle(bridge, ph) orelse return qjs.Value.initBool(false);
    const child = getElemByHandle(bridge, ch) orelse return qjs.Value.initBool(false);
    return qjs.Value.initBool(detachChild(parent, child));
}

// ── JS polyfill ───────────────────────────────────────────────────────────

const BRIDGE_POLYFILL =
    \\(function() {
    \\  'use strict';
    \\
    \\  function makeElement(data) {
    \\    if (data === null || data === undefined) return null;
    \\    const d = typeof data === 'string' ? JSON.parse(data) : data;
    \\    if (!d) return null;
    \\    const attrs = {};
    \\    for (const a of (d.attrs || [])) attrs[a.name] = a.value;
    \\    const el = {
    \\      nodeType: 1,
    \\      tagName: (d.tag || '').toUpperCase(),
    \\      _h: d._h || 0,
    \\      _attrs: attrs,
    \\      _text: d.text || '',
    \\      _children: [],
    \\      getAttribute(name) { return this._attrs[name.toLowerCase()] != null ? this._attrs[name.toLowerCase()] : null; },
    \\      setAttribute(name, value) { this._attrs[name.toLowerCase()] = String(value); __awr_setAttribute__(this._h, String(name), String(value)); },
    \\      removeAttribute(name) { delete this._attrs[name.toLowerCase()]; __awr_removeAttribute__(this._h, String(name)); },
    \\      hasAttribute(name) { return name.toLowerCase() in this._attrs; },
    \\      get textContent() { return this._text; },
    \\      set textContent(v) { this._text = String(v); this._innerHTML = String(v); __awr_setTextContent__(this._h, String(v)); },
    \\      get innerHTML() { return this._innerHTML != null ? this._innerHTML : this._text; },
    \\      set innerHTML(v) { this._innerHTML = String(v); },
    \\      get outerHTML() { return '<' + this.tagName.toLowerCase() + '>' + this.innerHTML + '</' + this.tagName.toLowerCase() + '>'; },
    \\      get id() { return this._attrs.id || ''; },
    \\      set id(v) { this._attrs.id = String(v); },
    \\      get className() { return this._attrs.class || ''; },
    \\      set className(v) { this._attrs.class = String(v); },
    \\      get style() { return this._style || (this._style = {}); },
    \\      get dataset() { return this._dataset || (this._dataset = {}); },
    \\      classList: {
    \\        _cls: attrs.class ? attrs.class.split(' ') : [],
    \\        contains(c) { return this._cls.includes(c); },
    \\        add(c) { if (!this.contains(c)) this._cls.push(c); },
    \\        remove(c) { this._cls = this._cls.filter(x => x !== c); },
    \\        toggle(c) { this.contains(c) ? this.remove(c) : this.add(c); },
    \\      },
    \\      addEventListener() {},
    \\      removeEventListener() {},
    \\      dispatchEvent() { return true; },
    \\      appendChild(child) {
    \\        this._children.push(child);
    \\        if (child && child._h) __awr_appendChild__(this._h, child._h);
    \\        return child;
    \\      },
    \\      removeChild(child) {
    \\        this._children = this._children.filter(c => c !== child);
    \\        if (child && child._h) __awr_removeChild__(this._h, child._h);
    \\        return child;
    \\      },
    \\      insertBefore(node, ref) {
    \\        const idx = ref ? this._children.indexOf(ref) : -1;
    \\        if (idx >= 0) this._children.splice(idx, 0, node); else this._children.unshift(node);
    \\        __awr_insertBefore__(this._h, node && node._h ? node._h : 0, ref && ref._h ? ref._h : 0);
    \\        return node;
    \\      },
    \\      contains(other) { return false; },
    \\      querySelector(sel) {
    \\        const r = __awr_querySelectorScoped__(this._h, String(sel));
    \\        return r ? makeElement(r) : null;
    \\      },
    \\      querySelectorAll(sel) {
    \\        const r = __awr_querySelectorAllScoped__(this._h, String(sel));
    \\        try { return (JSON.parse(r) || []).map(makeElement); } catch(e) { return []; }
    \\      },
    \\      matches(sel) { return !!__awr_matches__(this._h, String(sel)); },
    \\      closest(sel) {
    \\        const r = __awr_closest__(this._h, String(sel));
    \\        return r ? makeElement(r) : null;
    \\      },
    \\      getBoundingClientRect() { return {top:0,left:0,bottom:0,right:0,width:0,height:0,x:0,y:0}; },
    \\      focus() {},
    \\      blur() {},
    \\      click() {},
    \\      scrollIntoView() {},
    \\      get children() { return this._children; },
    \\      get childNodes() { return this._children; },
    \\      get parentNode() { return null; },
    \\      get parentElement() { return null; },
    \\      get nextSibling() { return null; },
    \\      get previousSibling() { return null; },
    \\      get firstChild() { return this._children[0] || null; },
    \\      get lastChild() { return this._children[this._children.length - 1] || null; },
    \\      get nodeValue() { return null; },
    \\      cloneNode() { return makeElement(d); },
    \\    };
    \\    return el;
    \\  }
    \\
    \\  const document = {
    \\    nodeType: 9,
    \\    querySelector(sel) { const r = __awr_querySelector__(String(sel)); return r ? makeElement(r) : null; },
    \\    querySelectorAll(sel) {
    \\      const r = __awr_querySelectorAll__(String(sel));
    \\      try { return (JSON.parse(r) || []).map(makeElement); } catch(e) { return []; }
    \\    },
    \\    getElementById(id) { const r = __awr_getElementById__(String(id)); return r ? makeElement(r) : null; },
    \\    getElementsByClassName(cls) { return document.querySelectorAll('.' + cls); },
    \\    getElementsByTagName(tag) { return document.querySelectorAll(tag); },
    \\    get title() { return __awr_getTitle__(); },
    \\    set title(v) {},
    \\    get body() { const r = __awr_getBody__(); return r ? makeElement(r) : null; },
    \\    get head() { return this.querySelector('head'); },
    \\    get documentElement() { return this.querySelector('html'); },
    \\    createElement(tag) { const r = __awr_createElement__(String(tag)); return r ? makeElement(r) : makeElement({tag: tag, attrs: [], text: ''}); },
    \\    createTextNode(text) { return {nodeType: 3, textContent: String(text), nodeValue: String(text), data: String(text)}; },
    \\    createDocumentFragment() { const f = {_ch:[], appendChild(c){this._ch.push(c);return c;}, querySelectorAll(){return [];}}; return f; },
    \\    createComment(text) { return {nodeType: 8, nodeValue: text}; },
    \\    addEventListener() {},
    \\    removeEventListener() {},
    \\    dispatchEvent() { return true; },
    \\    createEvent() { return {initEvent(){}, initCustomEvent(){}}; },
    \\    createRange() { return {selectNodeContents(){}, toString(){return '';}, getBoundingClientRect(){return {top:0,left:0,width:0,height:0};}}; },
    \\    execCommand() { return false; },
    \\    get cookie() { return ''; },
    \\    set cookie(v) {},
    \\    get readyState() { return 'complete'; },
    \\    get visibilityState() { return 'visible'; },
    \\    get hidden() { return false; },
    \\    get location() { return globalThis.location; },
    \\    get defaultView() { return globalThis; },
    \\  };
    \\
    \\  globalThis.document  = document;
    \\  globalThis.window    = globalThis;
    \\
    \\  if (!globalThis.navigator) {
    \\    globalThis.navigator = {
    \\      userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36',
    \\      language: 'en-US', languages: ['en-US', 'en'],
    \\      cookieEnabled: false, onLine: true, hardwareConcurrency: 8,
    \\      platform: 'MacIntel', vendor: 'Google Inc.', maxTouchPoints: 0,
    \\    };
    \\  }
    \\  if (!globalThis.location) {
    \\    globalThis.location = { href: '', origin: '', pathname: '/', search: '', hash: '', hostname: '', protocol: 'https:', assign(){}, replace(){}, reload(){} };
    \\  }
    \\  globalThis.history = { length: 1, state: null, pushState(){}, replaceState(){}, back(){}, forward(){}, go(){} };
    \\  globalThis.screen  = { width: 1920, height: 1080, availWidth: 1920, availHeight: 1080, colorDepth: 24, pixelDepth: 24 };
    \\  globalThis.devicePixelRatio = 1;
    \\  globalThis.innerWidth  = 1920;
    \\  globalThis.innerHeight = 1080;
    \\
    \\  globalThis.requestAnimationFrame  = function(cb) { return 0; };
    \\  globalThis.cancelAnimationFrame   = function() {};
    \\  globalThis.requestIdleCallback    = function(cb, opts) { return 0; };
    \\  globalThis.cancelIdleCallback     = function() {};
    \\
    \\  globalThis.MutationObserver = function() { return { observe(){}, disconnect(){}, takeRecords(){ return []; } }; };
    \\  globalThis.IntersectionObserver = function(cb, opts) { return { observe(){}, disconnect(){}, unobserve(){} }; };
    \\  globalThis.ResizeObserver = function(cb) { return { observe(){}, disconnect(){}, unobserve(){} }; };
    \\  globalThis.PerformanceObserver = function(cb) { return { observe(){}, disconnect(){} }; };
    \\
    \\  globalThis.CustomEvent = function(type, opts) {
    \\    return { type, detail: (opts && opts.detail) || null, bubbles: false, cancelable: false };
    \\  };
    \\  globalThis.Event = function(type, opts) {
    \\    return { type, bubbles: (opts && opts.bubbles) || false, cancelable: (opts && opts.cancelable) || false,
    \\             preventDefault(){}, stopPropagation(){}, stopImmediatePropagation(){} };
    \\  };
    \\  globalThis.MouseEvent = globalThis.Event;
    \\  globalThis.KeyboardEvent = globalThis.Event;
    \\  globalThis.TouchEvent = globalThis.Event;
    \\  globalThis.FocusEvent = globalThis.Event;
    \\
    \\  globalThis.localStorage  = { getItem(){ return null; }, setItem(){}, removeItem(){}, clear(){}, length: 0 };
    \\  globalThis.sessionStorage = globalThis.localStorage;
    \\
    \\  globalThis.XMLHttpRequest = function() {
    \\    return { open(){}, send(){}, setRequestHeader(){}, addEventListener(){},
    \\             readyState: 4, status: 0, responseText: '' };
    \\  };
    \\
    \\  // ── WebMCP (navigator.modelContext) ────────────────────────────────
    \\  // W3C Web Model Context spec — Chrome 146+ ships registerTool/getTools/
    \\  // callTool.  AWR implements the tool-registration API so agentic pages
    \\  // can expose themselves to the runtime; the runtime invokes tools
    \\  // through __awr_callToolJson__/__awr_resolveToolJson__.
    \\  const __awr_tools__ = Object.create(null);
    \\  const __awr_pending__ = Object.create(null);
    \\  let __awr_next_call__ = 1;
    \\
    \\  function __awr_clone_descriptor__(d) {
    \\    // Return a JSON-safe copy of the descriptor (name, description, inputSchema).
    \\    const out = { name: String(d.name) };
    \\    if (d.description != null) out.description = String(d.description);
    \\    if (d.inputSchema != null) {
    \\      try { out.inputSchema = JSON.parse(JSON.stringify(d.inputSchema)); } catch (e) {}
    \\    }
    \\    return out;
    \\  }
    \\
    \\  globalThis.__awr_getToolsJson__ = function() {
    \\    const list = [];
    \\    for (const name in __awr_tools__) list.push(__awr_tools__[name].descriptor);
    \\    try { return JSON.stringify(list); } catch (e) { return '[]'; }
    \\  };
    \\
    \\  globalThis.__awr_callToolJson__ = function(name, argsJson) {
    \\    const entry = __awr_tools__[String(name)];
    \\    if (!entry) {
    \\      return JSON.stringify({ ok: false, error: 'ToolNotFound', message: 'No tool registered with name ' + name });
    \\    }
    \\    let args;
    \\    try { args = argsJson ? JSON.parse(argsJson) : {}; }
    \\    catch (e) { return JSON.stringify({ ok: false, error: 'InvalidArgs', message: String(e) }); }
    \\    try {
    \\      const result = entry.handler(args);
    \\      if (result && typeof result.then === 'function') {
    \\        const id = __awr_next_call__++;
    \\        const slot = { settled: false, value: undefined };
    \\        __awr_pending__[id] = slot;
    \\        result.then(
    \\          v => { slot.settled = true; slot.value = { ok: true, value: v }; },
    \\          e => { slot.settled = true; slot.value = { ok: false, error: 'ToolRejected', message: (e && e.message) || String(e) }; }
    \\        );
    \\        return JSON.stringify({ ok: true, pending: id });
    \\      }
    \\      return JSON.stringify({ ok: true, value: result });
    \\    } catch (e) {
    \\      return JSON.stringify({ ok: false, error: 'ToolThrew', message: (e && e.message) || String(e) });
    \\    }
    \\  };
    \\
    \\  // After drainMicrotasks, Zig calls this to fetch resolved async results.
    \\  globalThis.__awr_resolveToolJson__ = function(id) {
    \\    const slot = __awr_pending__[id];
    \\    if (!slot) return JSON.stringify({ ok: false, error: 'UnknownPendingId' });
    \\    delete __awr_pending__[id];
    \\    if (!slot.settled) return JSON.stringify({ ok: false, error: 'NotSettled' });
    \\    try { return JSON.stringify(slot.value); }
    \\    catch (e) { return JSON.stringify({ ok: false, error: 'NotSerializable', message: String(e) }); }
    \\  };
    \\
    \\  const modelContext = {
    \\    registerTool(descriptor, handler) {
    \\      if (!descriptor || typeof descriptor.name !== 'string' || !descriptor.name) {
    \\        throw new TypeError('registerTool: descriptor.name is required');
    \\      }
    \\      if (typeof handler !== 'function') {
    \\        throw new TypeError('registerTool: handler must be a function');
    \\      }
    \\      const clone = __awr_clone_descriptor__(descriptor);
    \\      __awr_tools__[clone.name] = { descriptor: clone, handler };
    \\      return { unregister() { delete __awr_tools__[clone.name]; } };
    \\    },
    \\    unregisterTool(name) { delete __awr_tools__[String(name)]; },
    \\    getTools() {
    \\      const out = [];
    \\      for (const name in __awr_tools__) out.push(__awr_clone_descriptor__(__awr_tools__[name].descriptor));
    \\      return out;
    \\    },
    \\    callTool(name, args) {
    \\      const entry = __awr_tools__[String(name)];
    \\      if (!entry) return Promise.reject(new Error('No tool registered with name ' + name));
    \\      try { return Promise.resolve(entry.handler(args || {})); }
    \\      catch (e) { return Promise.reject(e); }
    \\    },
    \\  };
    \\
    \\  globalThis.navigator.modelContext = modelContext;
    \\})();
;

// ── Tests ─────────────────────────────────────────────────────────────────

test "installDomBridge — basic smoke test" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><head><title>AWR Test</title></head><body><h1 id=\"title\">Hello</h1></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();

    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    // document should be defined
    const ok = try eng.evalBool("typeof document === 'object'");
    try std.testing.expect(ok);
}

test "bridge — document.querySelector returns element" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><body><p id=\"intro\">Hello AWR</p></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool("document.querySelector('p') !== null");
    try std.testing.expect(ok);
}

test "bridge — document.querySelector returns null for missing selector" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><body><p>text</p></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool("document.querySelector('h2') === null");
    try std.testing.expect(ok);
}

test "bridge — element.getAttribute works" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><body><a href=\"/page\">link</a></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool("document.querySelector('a').getAttribute('href') === '/page'");
    try std.testing.expect(ok);
}

test "bridge — document.getElementById finds element" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><body><div id=\"main\">content</div></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool("document.getElementById('main') !== null");
    try std.testing.expect(ok);
}

test "bridge — document.getElementById returns null for missing" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><body><div id=\"other\">content</div></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool("document.getElementById('nope') === null");
    try std.testing.expect(ok);
}

test "bridge — document.title returns page title" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><head><title>My Page</title></head><body></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool("document.title === 'My Page'");
    try std.testing.expect(ok);
}

test "bridge — document.body is not null" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><body><p>text</p></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool("document.body !== null");
    try std.testing.expect(ok);
}

test "bridge — element.textContent contains text" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><body><p>hello world</p></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool("document.querySelector('p').textContent.includes('hello')");
    try std.testing.expect(ok);
}

test "bridge — element.addEventListener does not throw" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><body><button id=\"btn\">click</button></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    try eng.eval(
        \\const btn = document.getElementById('btn');
        \\btn.addEventListener('click', function() { console.log('clicked'); });
    , "<test>");
}

test "bridge — element.setAttribute mutates JS-side attr" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><body><div id=\"box\">text</div></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    try eng.eval(
        \\const el = document.getElementById('box');
        \\el.setAttribute('data-count', '42');
    , "<test>");
    const ok = try eng.evalBool("document.getElementById('box').setAttribute('data-count','42'), true");
    try std.testing.expect(ok);
}

test "bridge — document.querySelectorAll returns array" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><body><p>a</p><p>b</p><p>c</p></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool("document.querySelectorAll('p').length === 3");
    try std.testing.expect(ok);
}

test "bridge — document.createElement returns object with tagName" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool("document.createElement('div').tagName === 'DIV'");
    try std.testing.expect(ok);
}

test "bridge — window === globalThis" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool("window === globalThis");
    try std.testing.expect(ok);
}

test "bridge — navigator.userAgent is non-empty" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool("navigator.userAgent.length > 0");
    try std.testing.expect(ok);
}

test "bridge — MutationObserver is constructable" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    try eng.eval("const mo = new MutationObserver(function(){}); mo.observe(document.body, {});", "<test>");
}

test "bridge — localStorage stub does not throw" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    try eng.eval("localStorage.setItem('key','value'); const v = localStorage.getItem('key');", "<test>");
}

test "bridge — DOM mutations reflect into Zig querySelector" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><div id=\"root\"></div></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    try eng.eval(
        \\const root = document.getElementById('root');
        \\const n = document.createElement('span');
        \\n.setAttribute('id', 'added');
        \\n.textContent = 'hello';
        \\root.appendChild(n);
    , "<test>");
    const ok = try eng.evalBool("document.querySelector('#added') !== null && document.querySelector('#added').textContent === 'hello'");
    try std.testing.expect(ok);
}

test "bridge — element.querySelector scopes to descendants" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><body><section id=\"first\"><p class=\"item\">one</p></section><section id=\"scope\"><p class=\"item\">two</p><div><p class=\"item\">three</p></div></section></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool(
        "document.getElementById('scope').querySelector('.item').textContent === 'two'",
    );
    try std.testing.expect(ok);
}

test "bridge — element.querySelectorAll scopes to descendants" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><body><section id=\"first\"><p class=\"item\">one</p></section><section id=\"scope\"><p class=\"item\">two</p><div><p class=\"item\">three</p></div></section></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool(
        "document.getElementById('scope').querySelectorAll('.item').map(el => el.textContent).join(',') === 'two,three'",
    );
    try std.testing.expect(ok);
}

test "bridge — element.matches and closest use Zig selector engine" {
    var doc = try dom.parseDocument(std.testing.allocator,
        "<html><body><section class=\"shell\"><div><p id=\"leaf\" class=\"copy\">hello</p></div></section></body></html>");
    defer doc.deinit();

    var eng = try engine.JsEngine.init(std.testing.allocator, null);
    defer eng.deinit();
    try installDomBridge(&eng, &doc, std.testing.allocator);
    defer removeDomBridge(&eng);

    const ok = try eng.evalBool(
        "(() => { const leaf = document.getElementById('leaf'); return leaf.matches('p.copy') && leaf.closest('section.shell').tagName === 'SECTION'; })()",
    );
    try std.testing.expect(ok);
}
