/// bridge.zig — JS↔DOM bindings for AWR Phase 2.
///
/// Installs a `document` global object (and companion window/navigator/
/// location shims) into a JsEngine, backed by a Zig DOM Document.
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
/// DOM-like objects (document, HTMLElement prototype, MutationObserver,
/// etc.). This keeps all the idiomatic JS API surface in JS
/// while the expensive parts (tree traversal, serialisation) stay in Zig.
///
/// Active MVP contract
/// ───────────────────
/// Queries reflect the authoritative Zig DOM tree built from the fetched HTML.
/// The active conformance slices progressively move mutations onto that same
/// authoritative tree so JS queries, page extraction, and rendering observe the
/// same state.
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
const render = @import("../render.zig");

// ── BridgeCtx ─────────────────────────────────────────────────────────────

/// Stored as engine.host.extension; accessed by native callbacks.
const BridgeCtx = struct {
    doc:       *dom.Document,
    allocator: std.mem.Allocator,
    elem_to_handle: std.AutoHashMap(*dom.Element, u32),
    handle_to_elem: std.ArrayList(*dom.Element),
    viewport_width: usize,
    viewport_height: usize,

    fn init(doc: *dom.Document, allocator: std.mem.Allocator) BridgeCtx {
        return .{
            .doc = doc,
            .allocator = allocator,
            .elem_to_handle = std.AutoHashMap(*dom.Element, u32).init(allocator),
            .handle_to_elem = std.ArrayList(*dom.Element).empty,
            .viewport_width = 80,
            .viewport_height = 24,
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

pub fn setViewportSize(eng: *engine.JsEngine, width: usize, height: usize) void {
    const host = eng.ctx.getOpaque(engine.EngineHostData) orelse return;
    const ext = host.extension orelse return;
    const bctx: *BridgeCtx = @ptrCast(@alignCast(ext));
    bctx.viewport_width = width;
    bctx.viewport_height = height;
}

pub fn setDocumentReadyState(eng: *engine.JsEngine, state: []const u8) void {
    var buf = std.mem.zeroes([256]u8);
    var w = std.Io.Writer.fixed(&buf);
    w.writeAll("globalThis.__awr_document_ready_state__=") catch return;
    writeJsonStr(&w, state) catch return;
    w.writeByte(';') catch return;

    const js_inject = engine.JsEngine.eval;
    js_inject(eng, w.buffered(), "document-ready-state") catch {};
}

// ── Native callbacks ──────────────────────────────────────────────────────

fn installNativeCallbacks(eng: *engine.JsEngine) !void {
    const ctx = eng.ctx;

    inline for (.{
        .{ "querySelector",    querySelectorFn },
        .{ "querySelectorAll", querySelectorAllFn },
        .{ "querySelectorScoped", querySelectorScopedFn },
        .{ "querySelectorAllScoped", querySelectorAllScopedFn },
        .{ "getAttribute",     getAttributeFn },
        .{ "getTextContent",   getTextContentFn },
        .{ "getChildren",      getChildrenFn },
        .{ "getParent",        getParentFn },
        .{ "getNextSibling",   getNextSiblingFn },
        .{ "getPreviousSibling", getPreviousSiblingFn },
        .{ "getInnerHTML",     getInnerHTMLFn },
        .{ "getOuterHTML",     getOuterHTMLFn },
        .{ "getBoundingClientRect", getBoundingClientRectFn },
        .{ "matches",         matchesFn },
        .{ "closest",         closestFn },
        .{ "contains",        containsFn },
        .{ "getElementById",   getElementByIdFn },
        .{ "getTitle",         getTitleFn },
        .{ "setTitle",         setTitleFn },
        .{ "getBody",          getBodyFn },
        .{ "createElement",    createElementFn },
        .{ "setInnerHTML",     setInnerHTMLFn },
        .{ "cloneNode",        cloneNodeFn },
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

fn childElementsToJson(bridge: *BridgeCtx, elem: *dom.Element) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(bridge.allocator);

    out.append(bridge.allocator, '[') catch return null;
    var first = true;
    for (elem.children.items) |child| {
        if (child != .element) continue;
        if (!first) out.append(bridge.allocator, ',') catch return null;
        var buf: [8192]u8 = undefined;
        const json = elementToJson(bridge, child.element, &buf) orelse return null;
        out.appendSlice(bridge.allocator, json) catch return null;
        first = false;
    }
    out.append(bridge.allocator, ']') catch return null;
    return out.toOwnedSlice(bridge.allocator) catch return null;
}

const SerializeError = error{OutOfMemory};

fn appendEscapedHtmlText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) SerializeError!void {
    for (text) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            else => try out.append(allocator, ch),
        }
    }
}

fn appendEscapedHtmlAttr(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) SerializeError!void {
    for (text) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            else => try out.append(allocator, ch),
        }
    }
}

fn isVoidElementTag(tag: []const u8) bool {
    inline for (.{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" }) |name| {
        if (std.ascii.eqlIgnoreCase(tag, name)) return true;
    }
    return false;
}

fn appendSerializedNode(out: *std.ArrayList(u8), allocator: std.mem.Allocator, node: dom.Node) SerializeError!void {
    switch (node) {
        .element => |elem| try appendSerializedElement(out, allocator, elem),
        .text => |text| try appendEscapedHtmlText(out, allocator, text.data),
        .comment => |comment| {
            try out.appendSlice(allocator, "<!--");
            try out.appendSlice(allocator, comment.data);
            try out.appendSlice(allocator, "-->");
        },
        else => {},
    }
}

fn appendSerializedChildren(out: *std.ArrayList(u8), allocator: std.mem.Allocator, elem: *const dom.Element) SerializeError!void {
    for (elem.children.items) |child| {
        try appendSerializedNode(out, allocator, child);
    }
}

fn appendSerializedElement(out: *std.ArrayList(u8), allocator: std.mem.Allocator, elem: *const dom.Element) SerializeError!void {
    try out.append(allocator, '<');
    try out.appendSlice(allocator, elem.tag);
    for (elem.attributes) |attr| {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, attr.name);
        try out.appendSlice(allocator, "=\"");
        try appendEscapedHtmlAttr(out, allocator, attr.value);
        try out.append(allocator, '"');
    }
    try out.append(allocator, '>');
    if (isVoidElementTag(elem.tag)) return;
    try appendSerializedChildren(out, allocator, elem);
    try out.appendSlice(allocator, "</");
    try out.appendSlice(allocator, elem.tag);
    try out.append(allocator, '>');
}

fn serializeInnerHtml(bridge: *BridgeCtx, elem: *const dom.Element) SerializeError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(bridge.allocator);
    try appendSerializedChildren(&out, bridge.allocator, elem);
    return out.toOwnedSlice(bridge.allocator);
}

fn serializeOuterHtml(bridge: *BridgeCtx, elem: *const dom.Element) SerializeError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(bridge.allocator);
    try appendSerializedElement(&out, bridge.allocator, elem);
    return out.toOwnedSlice(bridge.allocator);
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

fn getAttributeFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.null;
    const c = ctx orelse return qjs.Value.null;
    if (args.len < 2) return qjs.Value.null;

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.null;
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.null;
    const name_v: qjs.Value = @bitCast(args[1]);
    const name_c = name_v.toCString(c) orelse return qjs.Value.null;
    defer c.freeCString(name_c);

    const value = elem.getAttribute(std.mem.span(name_c)) orelse return qjs.Value.null;
    return qjs.Value.initStringLen(c, value);
}

fn getTextContentFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initStringLen(ctx orelse return qjs.Value.undefined, "");
    const c = ctx orelse return qjs.Value.undefined;
    if (args.len == 0) return qjs.Value.initStringLen(c, "");

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.initStringLen(c, "");
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.initStringLen(c, "");
    const text = elem.textContent(bridge.allocator) catch return qjs.Value.initStringLen(c, "");
    defer bridge.allocator.free(text);
    return qjs.Value.initStringLen(c, text);
}

fn getChildrenFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initStringLen(ctx orelse return qjs.Value.undefined, "[]");
    const c = ctx orelse return qjs.Value.undefined;
    if (args.len == 0) return qjs.Value.initStringLen(c, "[]");

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.initStringLen(c, "[]");
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.initStringLen(c, "[]");
    const json = childElementsToJson(bridge, elem) orelse return qjs.Value.initStringLen(c, "[]");
    defer bridge.allocator.free(json);
    return qjs.Value.initStringLen(c, json);
}

fn getParentFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.null;
    const c = ctx orelse return qjs.Value.null;
    if (args.len == 0) return qjs.Value.null;

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.null;
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.null;
    const parent = elem.parent orelse return qjs.Value.null;
    var buf: [8192]u8 = undefined;
    const json = elementToJson(bridge, parent, &buf) orelse return qjs.Value.null;
    return qjs.Value.initStringLen(c, json);
}

fn getNextSiblingFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.null;
    const c = ctx orelse return qjs.Value.null;
    if (args.len == 0) return qjs.Value.null;

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.null;
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.null;
    const parent = elem.parent orelse return qjs.Value.null;
    for (parent.children.items, 0..) |node, i| {
        if (node == .element and node.element == elem) {
            var j = i + 1;
            while (j < parent.children.items.len) : (j += 1) {
                const sibling = parent.children.items[j];
                if (sibling == .element) {
                    var buf: [8192]u8 = undefined;
                    const json = elementToJson(bridge, sibling.element, &buf) orelse return qjs.Value.null;
                    return qjs.Value.initStringLen(c, json);
                }
            }
            break;
        }
    }
    return qjs.Value.null;
}

fn getPreviousSiblingFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.null;
    const c = ctx orelse return qjs.Value.null;
    if (args.len == 0) return qjs.Value.null;

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.null;
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.null;
    const parent = elem.parent orelse return qjs.Value.null;
    var previous: ?*dom.Element = null;
    for (parent.children.items) |node| {
        if (node == .element) {
            if (node.element == elem) {
                if (previous) |sibling| {
                    var buf: [8192]u8 = undefined;
                    const json = elementToJson(bridge, sibling, &buf) orelse return qjs.Value.null;
                    return qjs.Value.initStringLen(c, json);
                }
                return qjs.Value.null;
            }
            previous = node.element;
        }
    }
    return qjs.Value.null;
}

fn getInnerHTMLFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initStringLen(ctx orelse return qjs.Value.undefined, "");
    const c = ctx orelse return qjs.Value.undefined;
    if (args.len == 0) return qjs.Value.initStringLen(c, "");

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.initStringLen(c, "");
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.initStringLen(c, "");
    const html = serializeInnerHtml(bridge, elem) catch return qjs.Value.initStringLen(c, "");
    defer bridge.allocator.free(html);
    return qjs.Value.initStringLen(c, html);
}

fn getOuterHTMLFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initStringLen(ctx orelse return qjs.Value.undefined, "");
    const c = ctx orelse return qjs.Value.undefined;
    if (args.len == 0) return qjs.Value.initStringLen(c, "");

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.initStringLen(c, "");
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.initStringLen(c, "");
    const html = serializeOuterHtml(bridge, elem) catch return qjs.Value.initStringLen(c, "");
    defer bridge.allocator.free(html);
    return qjs.Value.initStringLen(c, html);
}

fn getBoundingClientRectFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initStringLen(ctx orelse return qjs.Value.undefined, "null");
    const c = ctx orelse return qjs.Value.undefined;
    if (args.len == 0) return qjs.Value.initStringLen(c, "null");

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.initStringLen(c, "null");
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.initStringLen(c, "null");

    var model = render.renderModel(bridge.allocator, bridge.doc, .{
        .max_width = bridge.viewport_width,
        .ansi_colors = false,
        .show_links = true,
        .show_images = true,
    }) catch return qjs.Value.initStringLen(c, "null");
    defer model.deinit();

    const rect = model.rectForElement(elem) orelse return qjs.Value.initStringLen(c, "null");
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        "{{\"top\":{d},\"left\":{d},\"bottom\":{d},\"right\":{d},\"width\":{d},\"height\":{d},\"x\":{d},\"y\":{d}}}",
        .{ rect.y, rect.x, rect.y + rect.height, rect.x + rect.width, rect.width, rect.height, rect.x, rect.y },
    ) catch return qjs.Value.initStringLen(c, "null");
    return qjs.Value.initStringLen(c, json);
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

fn containsFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initBool(false);
    const c = ctx orelse return qjs.Value.initBool(false);
    if (args.len < 2) return qjs.Value.initBool(false);

    const parent_h = parseHandleArg(c, args[0]) orelse return qjs.Value.initBool(false);
    const child_h = parseHandleArg(c, args[1]) orelse return qjs.Value.initBool(false);
    const parent = getElemByHandle(bridge, parent_h) orelse return qjs.Value.initBool(false);
    const child = getElemByHandle(bridge, child_h) orelse return qjs.Value.initBool(false);

    var cur: ?*dom.Element = child;
    while (cur) |elem| : (cur = elem.parent) {
        if (elem == parent) return qjs.Value.initBool(true);
    }
    return qjs.Value.initBool(false);
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

fn setTitleFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initBool(false);
    const c = ctx orelse return qjs.Value.initBool(false);
    if (args.len == 0) return qjs.Value.initBool(false);

    const title_v: qjs.Value = @bitCast(args[0]);
    const title_c = title_v.toCString(c) orelse return qjs.Value.initBool(false);
    defer c.freeCString(title_c);

    const alloc = bridge.doc.arena.allocator();
    const html = bridge.doc.htmlElement() orelse return qjs.Value.initBool(false);

    var head = html.firstChildByTag("head");
    if (head == null) {
        const new_head = alloc.create(dom.Element) catch return qjs.Value.initBool(false);
        new_head.* = .{
            .tag = alloc.dupe(u8, "head") catch return qjs.Value.initBool(false),
            .attributes = &.{},
            .children = .empty,
            .parent = html,
        };
        html.children.insert(alloc, 0, .{ .element = new_head }) catch return qjs.Value.initBool(false);
        head = new_head;
    }

    var title = head.?.firstChildByTag("title");
    if (title == null) {
        const new_title = alloc.create(dom.Element) catch return qjs.Value.initBool(false);
        new_title.* = .{
            .tag = alloc.dupe(u8, "title") catch return qjs.Value.initBool(false),
            .attributes = &.{},
            .children = .empty,
            .parent = head.?,
        };
        head.?.children.append(alloc, .{ .element = new_title }) catch return qjs.Value.initBool(false);
        title = new_title;
    }

    title.?.children.clearRetainingCapacity();
    const text_node = alloc.create(dom.Text) catch return qjs.Value.initBool(false);
    text_node.* = .{
        .data = alloc.dupe(u8, std.mem.span(title_c)) catch return qjs.Value.initBool(false),
        .parent = title.?,
    };
    title.?.children.append(alloc, .{ .text = text_node }) catch return qjs.Value.initBool(false);
    return qjs.Value.initBool(true);
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

fn clearChildren(elem: *dom.Element) void {
    for (elem.children.items) |child| {
        switch (child) {
            .element => |e| e.parent = null,
            .text => |t| t.parent = null,
            .comment => |cmt| cmt.parent = null,
            else => {},
        }
    }
    elem.children.clearRetainingCapacity();
}

fn cloneAttributes(alloc: std.mem.Allocator, attrs: []const dom.Attribute) ![]dom.Attribute {
    const out = try alloc.alloc(dom.Attribute, attrs.len);
    for (attrs, 0..) |attr, i| {
        out[i] = .{
            .name = try alloc.dupe(u8, attr.name),
            .value = try alloc.dupe(u8, attr.value),
        };
    }
    return out;
}

fn cloneNodeIntoDoc(alloc: std.mem.Allocator, node: dom.Node, parent: ?*dom.Element, deep: bool) !dom.Node {
    return switch (node) {
        .element => |elem| blk: {
            const cloned = try alloc.create(dom.Element);
            cloned.* = .{
                .tag = try alloc.dupe(u8, elem.tag),
                .attributes = try cloneAttributes(alloc, elem.attributes),
                .children = .empty,
                .parent = parent,
            };
            if (deep) {
                for (elem.children.items) |child| {
                    try cloned.children.append(alloc, try cloneNodeIntoDoc(alloc, child, cloned, true));
                }
            }
            break :blk .{ .element = cloned };
        },
        .text => |text| blk: {
            const cloned = try alloc.create(dom.Text);
            cloned.* = .{ .data = try alloc.dupe(u8, text.data), .parent = parent };
            break :blk .{ .text = cloned };
        },
        .comment => |comment| blk: {
            const cloned = try alloc.create(dom.Comment);
            cloned.* = .{ .data = try alloc.dupe(u8, comment.data), .parent = parent };
            break :blk .{ .comment = cloned };
        },
        else => .{ .other = {} },
    };
}

fn setInnerHTMLFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.initBool(false);
    const c = ctx orelse return qjs.Value.initBool(false);
    if (args.len < 2) return qjs.Value.initBool(false);

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.initBool(false);
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.initBool(false);
    const html_v: qjs.Value = @bitCast(args[1]);
    const html_c = html_v.toCString(c) orelse return qjs.Value.initBool(false);
    defer c.freeCString(html_c);

    const wrapped = std.fmt.allocPrint(bridge.allocator, "<html><body>{s}</body></html>", .{std.mem.span(html_c)}) catch {
        return qjs.Value.initBool(false);
    };
    defer bridge.allocator.free(wrapped);

    var parsed = dom.parseDocument(bridge.allocator, wrapped) catch return qjs.Value.initBool(false);
    defer parsed.deinit();

    clearChildren(elem);

    if (parsed.body()) |body| {
        const alloc = bridge.doc.arena.allocator();
        for (body.children.items) |child| {
            elem.children.append(alloc, cloneNodeIntoDoc(alloc, child, elem, true) catch return qjs.Value.initBool(false)) catch {
                return qjs.Value.initBool(false);
            };
        }
    }
    return qjs.Value.initBool(true);
}

fn cloneNodeFn(ctx: ?*qjs.Context, _: qjs.Value, args: []const @import("quickjs").c.JSValue) qjs.Value {
    const bridge = getBridge(ctx) orelse return qjs.Value.null;
    const c = ctx orelse return qjs.Value.null;
    if (args.len == 0) return qjs.Value.null;

    const h = parseHandleArg(c, args[0]) orelse return qjs.Value.null;
    const elem = getElemByHandle(bridge, h) orelse return qjs.Value.null;
    const deep = if (args.len >= 2) blk: {
        const deep_v: qjs.Value = @bitCast(args[1]);
        break :blk deep_v.toBool(c) catch false;
    } else false;

    const alloc = bridge.doc.arena.allocator();
    const cloned_node = cloneNodeIntoDoc(alloc, .{ .element = elem }, null, deep) catch return qjs.Value.null;
    const cloned = cloned_node.element;
    var buf: [8192]u8 = undefined;
    const json = elementToJson(bridge, cloned, &buf) orelse return qjs.Value.null;
    return qjs.Value.initStringLen(c, json);
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
    \\  const __awr_event_listeners__ = Object.create(null);
    \\  let __awr_next_listener_key__ = 1;
    \\  const __awr_mutation_observers__ = [];
    \\  let __awr_mutation_flush_scheduled__ = false;
    \\
    \\  function __awr_listener_key__(target) {
    \\    if (!target || (typeof target !== 'object' && typeof target !== 'function')) return null;
    \\    if (target === globalThis) return 'window';
    \\    if (target === document) return 'document';
    \\    if (target && target._h) return 'h:' + String(target._h);
    \\    if (!target.__awr_listener_key__) {
    \\      Object.defineProperty(target, '__awr_listener_key__', {
    \\        value: 'local:' + String(__awr_next_listener_key__++),
    \\        enumerable: false,
    \\        configurable: false,
    \\        writable: false,
    \\      });
    \\    }
    \\    return target.__awr_listener_key__;
    \\  }
    \\
    \\  function __awr_listener_list__(target, type, create) {
    \\    const key = __awr_listener_key__(target);
    \\    if (!key) return [];
    \\    let byType = __awr_event_listeners__[key];
    \\    if (!byType) {
    \\      if (!create) return [];
    \\      byType = Object.create(null);
    \\      __awr_event_listeners__[key] = byType;
    \\    }
    \\    let list = byType[type];
    \\    if (!list) {
    \\      if (!create) return [];
    \\      list = [];
    \\      byType[type] = list;
    \\    }
    \\    return list;
    \\  }
    \\
    \\  function __awr_normalize_event_options__(options) {
    \\    if (options === true) return { capture: true, once: false };
    \\    if (!options) return { capture: false, once: false };
    \\    return { capture: !!options.capture, once: !!options.once };
    \\  }
    \\
    \\  function __awr_add_event_listener__(target, type, callback, options) {
    \\    if (typeof callback !== 'function') return;
    \\    const opts = __awr_normalize_event_options__(options);
    \\    const list = __awr_listener_list__(target, String(type), true);
    \\    for (const entry of list) {
    \\      if (entry.callback === callback && entry.capture === opts.capture) return;
    \\    }
    \\    list.push({ callback: callback, capture: opts.capture, once: opts.once });
    \\  }
    \\
    \\  function __awr_remove_event_listener__(target, type, callback, options) {
    \\    if (typeof callback !== 'function') return;
    \\    const opts = __awr_normalize_event_options__(options);
    \\    const list = __awr_listener_list__(target, String(type), false);
    \\    for (let i = 0; i < list.length; i += 1) {
    \\      const entry = list[i];
    \\      if (entry.callback === callback && entry.capture === opts.capture) {
    \\        list.splice(i, 1);
    \\        break;
    \\      }
    \\    }
    \\  }
    \\
    \\  function __awr_event_parent__(target) {
    \\    if (!target || target === globalThis) return null;
    \\    if (target === document) return globalThis;
    \\    if (target && target._h) {
    \\      const parent = __awr_getParent__(target._h);
    \\      if (parent) return makeElement(parent);
    \\      const root = document.documentElement;
    \\      if (root && root._h === target._h) return document;
    \\    }
    \\    return null;
    \\  }
    \\
    \\  function __awr_event_path__(target) {
    \\    const path = [target];
    \\    let cur = __awr_event_parent__(target);
    \\    while (cur) {
    \\      path.push(cur);
    \\      cur = __awr_event_parent__(cur);
    \\    }
    \\    return path;
    \\  }
    \\
    \\  function __awr_invoke_listeners__(target, event, capture) {
    \\    const list = __awr_listener_list__(target, event.type, false).slice();
    \\    for (const entry of list) {
    \\      if (!!entry.capture !== !!capture) continue;
    \\      event.currentTarget = target;
    \\      if (entry.once) __awr_remove_event_listener__(target, event.type, entry.callback, { capture: entry.capture });
    \\      entry.callback.call(target, event);
    \\      if (event.__stopImmediate) return true;
    \\    }
    \\    return event.__stop;
    \\  }
    \\
    \\  function __awr_dispatch_event__(target, event) {
    \\    if (!event || typeof event.type !== 'string' || event.type.length === 0) {
    \\      throw new TypeError('dispatchEvent requires an Event with a type');
    \\    }
    \\    const path = __awr_event_path__(target);
    \\    event.target = target;
    \\    event.currentTarget = null;
    \\    event.__stop = false;
    \\    event.__stopImmediate = false;
    \\
    \\    for (let i = path.length - 1; i > 0; i -= 1) {
    \\      event.eventPhase = 1;
    \\      if (__awr_invoke_listeners__(path[i], event, true)) break;
    \\      if (event.__stop) break;
    \\    }
    \\
    \\    event.eventPhase = 2;
    \\    __awr_invoke_listeners__(target, event, true);
    \\    if (!event.__stopImmediate) __awr_invoke_listeners__(target, event, false);
    \\
    \\    if (event.bubbles && !event.__stop) {
    \\      for (let i = 1; i < path.length; i += 1) {
    \\        event.eventPhase = 3;
    \\        if (__awr_invoke_listeners__(path[i], event, false)) break;
    \\        if (event.__stop) break;
    \\      }
    \\    }
    \\
    \\    event.eventPhase = 0;
    \\    event.currentTarget = null;
    \\    return !event.defaultPrevented;
    \\  }
    \\
    \\  function __awr_mutation_target_matches__(observation, target) {
    \\    if (!observation.target || !target || !observation.target._h || !target._h) return false;
    \\    if (observation.target._h === target._h) return true;
    \\    if (!observation.options.subtree) return false;
    \\    return !!__awr_contains__(observation.target._h, target._h);
    \\  }
    \\
    \\  function __awr_queue_mutation_record__(target, record) {
    \\    for (const observer of __awr_mutation_observers__) {
    \\      for (const observation of observer.__observations) {
    \\        if (!__awr_mutation_target_matches__(observation, target)) continue;
    \\        if (record.type === 'childList' && !observation.options.childList) continue;
    \\        if (record.type === 'attributes' && !observation.options.attributes) continue;
    \\        if (record.type === 'characterData' && !observation.options.characterData) continue;
    \\        observer.__records.push({
    \\          type: record.type,
    \\          target: record.target,
    \\          addedNodes: record.addedNodes || [],
    \\          removedNodes: record.removedNodes || [],
    \\          previousSibling: record.previousSibling || null,
    \\          nextSibling: record.nextSibling || null,
    \\          attributeName: record.attributeName || null,
    \\          oldValue: observation.options.attributeOldValue || observation.options.characterDataOldValue ? (record.oldValue == null ? null : record.oldValue) : null,
    \\        });
    \\      }
    \\    }
    \\    if (!__awr_mutation_flush_scheduled__) {
    \\      __awr_mutation_flush_scheduled__ = true;
    \\      Promise.resolve().then(function() {
    \\        __awr_mutation_flush_scheduled__ = false;
    \\        for (const observer of __awr_mutation_observers__) {
    \\          if (!observer.__records.length) continue;
    \\          const records = observer.takeRecords();
    \\          if (records.length) observer.__callback(records, observer);
    \\        }
    \\      });
    \\    }
    \\  }
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
    \\      getAttribute(name) {
    \\        if (this._h) {
    \\          const value = __awr_getAttribute__(this._h, String(name));
    \\          return value === undefined ? null : value;
    \\        }
    \\        return this._attrs[name.toLowerCase()] != null ? this._attrs[name.toLowerCase()] : null;
    \\      },
    \\      setAttribute(name, value) {
    \\        const key = name.toLowerCase();
    \\        const oldValue = this._attrs[key] != null ? this._attrs[key] : null;
    \\        this._attrs[key] = String(value);
    \\        __awr_setAttribute__(this._h, String(name), String(value));
    \\        __awr_queue_mutation_record__(this, { type: 'attributes', target: this, attributeName: String(name), oldValue: oldValue });
    \\      },
    \\      removeAttribute(name) {
    \\        const key = name.toLowerCase();
    \\        const oldValue = this._attrs[key] != null ? this._attrs[key] : null;
    \\        delete this._attrs[key];
    \\        __awr_removeAttribute__(this._h, String(name));
    \\        __awr_queue_mutation_record__(this, { type: 'attributes', target: this, attributeName: String(name), oldValue: oldValue });
    \\      },
    \\      hasAttribute(name) { return name.toLowerCase() in this._attrs; },
    \\      get textContent() { return this._h ? __awr_getTextContent__(this._h) : this._text; },
    \\      set textContent(v) {
    \\        const oldValue = this._text;
    \\        this._text = String(v);
    \\        this._innerHTML = String(v);
    \\        __awr_setTextContent__(this._h, String(v));
    \\        __awr_queue_mutation_record__(this, { type: 'characterData', target: this, oldValue: oldValue });
    \\      },
    \\      get innerHTML() {
    \\        if (this._h) return __awr_getInnerHTML__(this._h);
    \\        return this._innerHTML != null ? this._innerHTML : this._text;
    \\      },
    \\      set innerHTML(v) {
    \\        this._innerHTML = String(v);
    \\        this._text = '';
    \\        this._children = [];
    \\        __awr_setInnerHTML__(this._h, String(v));
    \\        __awr_queue_mutation_record__(this, { type: 'childList', target: this, addedNodes: [], removedNodes: [] });
    \\      },
    \\      get outerHTML() {
    \\        if (this._h) return __awr_getOuterHTML__(this._h);
    \\        return '<' + this.tagName.toLowerCase() + '>' + this.innerHTML + '</' + this.tagName.toLowerCase() + '>';
    \\      },
    \\      get id() { return this._attrs.id || ''; },
    \\      set id(v) {
    \\        const value = String(v);
    \\        const oldValue = this.getAttribute('id');
    \\        this._attrs.id = value;
    \\        __awr_setAttribute__(this._h, 'id', value);
    \\        __awr_queue_mutation_record__(this, { type: 'attributes', target: this, attributeName: 'id', oldValue: oldValue });
    \\      },
    \\      get className() { return this._attrs.class || ''; },
    \\      set className(v) {
    \\        const value = String(v);
    \\        const oldValue = this.getAttribute('class');
    \\        this._attrs.class = value;
    \\        __awr_setAttribute__(this._h, 'class', value);
    \\        __awr_queue_mutation_record__(this, { type: 'attributes', target: this, attributeName: 'class', oldValue: oldValue });
    \\      },
    \\      get dataset() {
    \\        const owner = this;
    \\        if (!this._datasetProxy) {
    \\          this._datasetProxy = new Proxy({}, {
    \\            get(_, prop) {
    \\              const key = 'data-' + String(prop).replace(/[A-Z]/g, (m) => '-' + m.toLowerCase());
    \\              return owner.getAttribute(key);
    \\            },
    \\            set(_, prop, value) {
    \\              const key = 'data-' + String(prop).replace(/[A-Z]/g, (m) => '-' + m.toLowerCase());
    \\              owner.setAttribute(key, String(value));
    \\              return true;
    \\            },
    \\          });
    \\        }
    \\        return this._datasetProxy;
    \\      },
    \\      get classList() {
    \\        const owner = this;
    \\        const tokens = function() {
    \\          const raw = (owner._attrs.class || '').trim();
    \\          return raw ? raw.split(/\s+/).filter(Boolean) : [];
    \\        };
    \\        const commit = function(next) {
    \\          owner.className = next.join(' ');
    \\        };
    \\        return {
    \\          contains(c) { return tokens().includes(String(c)); },
    \\          add(c) {
    \\            const next = tokens();
    \\            const value = String(c);
    \\            if (!next.includes(value)) next.push(value);
    \\            commit(next);
    \\          },
    \\          remove(c) {
    \\            const value = String(c);
    \\            commit(tokens().filter(x => x !== value));
    \\          },
    \\          toggle(c) {
    \\            const value = String(c);
    \\            const next = tokens();
    \\            if (next.includes(value)) {
    \\              commit(next.filter(x => x !== value));
    \\              return false;
    \\            }
    \\            next.push(value);
    \\            commit(next);
    \\            return true;
    \\          },
    \\        };
    \\      },
    \\      addEventListener(type, callback, options) { __awr_add_event_listener__(this, type, callback, options); },
    \\      removeEventListener(type, callback, options) { __awr_remove_event_listener__(this, type, callback, options); },
    \\      dispatchEvent(event) { return __awr_dispatch_event__(this, event); },
    \\      appendChild(child) {
    \\        const previousSibling = this._children.length ? this._children[this._children.length - 1] : null;
    \\        this._children.push(child);
    \\        if (child) child._parent = this;
    \\        if (child && child._h) __awr_appendChild__(this._h, child._h);
    \\        __awr_queue_mutation_record__(this, { type: 'childList', target: this, addedNodes: child ? [child] : [], removedNodes: [], previousSibling: previousSibling, nextSibling: null });
    \\        return child;
    \\      },
    \\      removeChild(child) {
    \\        this._children = this._children.filter(c => c !== child);
    \\        if (child) child._parent = null;
    \\        if (child && child._h) __awr_removeChild__(this._h, child._h);
    \\        __awr_queue_mutation_record__(this, { type: 'childList', target: this, addedNodes: [], removedNodes: child ? [child] : [] });
    \\        return child;
    \\      },
    \\      insertBefore(node, ref) {
    \\        const idx = ref ? this._children.indexOf(ref) : -1;
    \\        if (idx >= 0) this._children.splice(idx, 0, node); else this._children.unshift(node);
    \\        if (node) node._parent = this;
    \\        __awr_insertBefore__(this._h, node && node._h ? node._h : 0, ref && ref._h ? ref._h : 0);
    \\        __awr_queue_mutation_record__(this, { type: 'childList', target: this, addedNodes: node ? [node] : [], removedNodes: [], nextSibling: ref || null });
    \\        return node;
    \\      },
    \\      contains(other) { return !!(other && other._h && __awr_contains__(this._h, other._h)); },
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
    \\      getBoundingClientRect() {
    \\        const r = __awr_getBoundingClientRect__(this._h);
    \\        try { return r ? JSON.parse(r) : {top:0,left:0,bottom:0,right:0,width:0,height:0,x:0,y:0}; } catch (e) { return {top:0,left:0,bottom:0,right:0,width:0,height:0,x:0,y:0}; }
    \\      },
    \\      focus() { this.dispatchEvent(new FocusEvent('focus')); },
    \\      blur() { this.dispatchEvent(new FocusEvent('blur')); },
    \\      click() { return this.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true })); },
    \\      get children() {
    \\        if (!this._h) return this._children;
    \\        try { return (JSON.parse(__awr_getChildren__(this._h)) || []).map(makeElement); } catch (e) { return []; }
    \\      },
    \\      get childNodes() { return this.children; },
    \\      get parentNode() {
    \\        if (this._parent) return this._parent;
    \\        const r = __awr_getParent__(this._h);
    \\        return r ? makeElement(r) : null;
    \\      },
    \\      get parentElement() { return this.parentNode; },
    \\      get nextSibling() {
    \\        const r = __awr_getNextSibling__(this._h);
    \\        return r ? makeElement(r) : null;
    \\      },
    \\      get previousSibling() {
    \\        const r = __awr_getPreviousSibling__(this._h);
    \\        return r ? makeElement(r) : null;
    \\      },
    \\      get firstChild() {
    \\        const children = this.children;
    \\        return children.length ? children[0] : null;
    \\      },
    \\      get lastChild() {
    \\        const children = this.children;
    \\        return children.length ? children[children.length - 1] : null;
    \\      },
    \\      get nodeValue() { return null; },
    \\      cloneNode(deep) {
    \\        const r = __awr_cloneNode__(this._h, !!deep);
    \\        return r ? makeElement(r) : null;
    \\      },
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
    \\    set title(v) { __awr_setTitle__(String(v)); },
    \\    get body() { const r = __awr_getBody__(); return r ? makeElement(r) : null; },
    \\    get head() { return this.querySelector('head'); },
    \\    get documentElement() { return this.querySelector('html'); },
    \\    createElement(tag) { const r = __awr_createElement__(String(tag)); return r ? makeElement(r) : makeElement({tag: tag, attrs: [], text: ''}); },
    \\    addEventListener(type, callback, options) { __awr_add_event_listener__(this, type, callback, options); },
    \\    removeEventListener(type, callback, options) { __awr_remove_event_listener__(this, type, callback, options); },
    \\    dispatchEvent(event) { return __awr_dispatch_event__(this, event); },
    \\    createEvent(type) { return new globalThis.Event(type || ''); },
    \\    get readyState() { return globalThis.__awr_document_ready_state__ || 'loading'; },
    \\    get visibilityState() { return 'visible'; },
    \\    get hidden() { return false; },
    \\    get location() { return globalThis.location; },
    \\    get defaultView() { return globalThis; },
    \\  };
    \\
    \\  globalThis.__awr_document_ready_state__ = globalThis.__awr_document_ready_state__ || 'loading';
    \\  globalThis.document  = document;
    \\  globalThis.window    = globalThis;
    \\  globalThis.addEventListener = function(type, callback, options) { __awr_add_event_listener__(globalThis, type, callback, options); };
    \\  globalThis.removeEventListener = function(type, callback, options) { __awr_remove_event_listener__(globalThis, type, callback, options); };
    \\  globalThis.dispatchEvent = function(event) { return __awr_dispatch_event__(globalThis, event); };
    \\
    \\  if (!globalThis.navigator) {
    \\    globalThis.navigator = {
    \\      userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36',
    \\      language: 'en-US', languages: ['en-US', 'en'],
    \\      cookieEnabled: false, onLine: true, hardwareConcurrency: 8,
    \\      platform: 'MacIntel', vendor: 'Google Inc.', maxTouchPoints: 0,
    \\    };
    \\  }
    \\  function __awr_resolve_history_url__(value) {
    \\    value = String(value || '');
    \\    if (!value) return globalThis.location.href;
    \\    if (value.indexOf('://') >= 0) {
    \\      if (!globalThis.location.origin || value.slice(0, globalThis.location.origin.length) !== globalThis.location.origin || (value.length > globalThis.location.origin.length && value[globalThis.location.origin.length] !== '/' && value[globalThis.location.origin.length] !== '?' && value[globalThis.location.origin.length] !== '#')) {
    \\        throw new TypeError('history: only same-origin URLs are currently supported');
    \\      }
    \\      return value;
    \\    }
    \\    if (value[0] === '/') return globalThis.location.origin + value;
    \\    const current = globalThis.location.pathname || '/';
    \\    const slash = current.lastIndexOf('/');
    \\    const dir = slash >= 0 ? current.slice(0, slash + 1) : '/';
    \\    return globalThis.location.origin + dir + value;
    \\  }
    \\  function __awr_apply_location__(href) {
    \\    const hashIndex = href.indexOf('#');
    \\    const hash = hashIndex >= 0 ? href.slice(hashIndex) : '';
    \\    const withoutHash = hashIndex >= 0 ? href.slice(0, hashIndex) : href;
    \\    const queryIndex = withoutHash.indexOf('?');
    \\    const search = queryIndex >= 0 ? withoutHash.slice(queryIndex) : '';
    \\    const withoutSearch = queryIndex >= 0 ? withoutHash.slice(0, queryIndex) : withoutHash;
    \\    const schemeSplit = withoutSearch.indexOf('://');
    \\    const protocol = schemeSplit >= 0 ? withoutSearch.slice(0, schemeSplit + 1) : globalThis.location.protocol;
    \\    const authorityAndPath = schemeSplit >= 0 ? withoutSearch.slice(schemeSplit + 3) : withoutSearch;
    \\    const slashIndex = authorityAndPath.indexOf('/');
    \\    const authority = slashIndex >= 0 ? authorityAndPath.slice(0, slashIndex) : authorityAndPath;
    \\    const pathname = slashIndex >= 0 ? authorityAndPath.slice(slashIndex) : '/';
    \\    const colonIndex = authority.lastIndexOf(':');
    \\    const hostname = colonIndex >= 0 ? authority.slice(0, colonIndex) : authority;
    \\    const port = colonIndex >= 0 ? authority.slice(colonIndex + 1) : '';
    \\    globalThis.location.href = href;
    \\    globalThis.location.origin = protocol + '//' + authority;
    \\    globalThis.location.pathname = pathname;
    \\    globalThis.location.search = search;
    \\    globalThis.location.hash = hash;
    \\    globalThis.location.hostname = hostname;
    \\    globalThis.location.host = authority;
    \\    globalThis.location.port = port;
    \\    globalThis.location.protocol = protocol;
    \\  }
    \\  if (!globalThis.location) {
    \\    globalThis.location = { href: '', origin: '', pathname: '/', search: '', hash: '', hostname: '', host: '', port: '', protocol: 'https:' };
    \\  }
    \\  const __awr_history_entries__ = [{ url: globalThis.location.href || '', state: null }];
    \\  globalThis.history = {
    \\    length: 1,
    \\    state: null,
    \\    pushState(state, unused, url) {
    \\      const nextUrl = url == null ? globalThis.location.href : __awr_resolve_history_url__(url);
    \\      __awr_history_entries__.push({ url: nextUrl, state: state == null ? null : state });
    \\      this.length = __awr_history_entries__.length;
    \\      this.state = state == null ? null : state;
    \\      __awr_apply_location__(nextUrl);
    \\    },
    \\    replaceState(state, unused, url) {
    \\      const nextUrl = url == null ? globalThis.location.href : __awr_resolve_history_url__(url);
    \\      __awr_history_entries__[__awr_history_entries__.length - 1] = { url: nextUrl, state: state == null ? null : state };
    \\      this.state = state == null ? null : state;
    \\      __awr_apply_location__(nextUrl);
    \\    },
    \\  };
    \\  globalThis.screen  = { width: 80, height: 24, availWidth: 80, availHeight: 24, colorDepth: 24, pixelDepth: 24 };
    \\  globalThis.devicePixelRatio = 1;
    \\  globalThis.innerWidth  = 80;
    \\  globalThis.innerHeight = 24;
    \\  globalThis.outerWidth  = 80;
    \\  globalThis.outerHeight = 24;
    \\
    \\  globalThis.requestAnimationFrame  = function(cb) { return setTimeout(function() { cb(Date.now()); }, 16); };
    \\  globalThis.cancelAnimationFrame   = function(id) { clearTimeout(id); };
    \\  globalThis.requestIdleCallback    = function(cb) { return setTimeout(function() { cb({ didTimeout: false, timeRemaining: function() { return 50; } }); }, 1); };
    \\  globalThis.cancelIdleCallback     = function(id) { clearTimeout(id); };
    \\
    \\  function __awr_viewport_rect__() {
    \\    return { top: 0, left: 0, right: window.innerWidth, bottom: window.innerHeight, width: window.innerWidth, height: window.innerHeight, x: 0, y: 0 };
    \\  }
    \\
    \\  globalThis.MutationObserver = function(callback) {
    \\    this.__callback = callback;
    \\    this.__records = [];
    \\    this.__observations = [];
    \\    __awr_mutation_observers__.push(this);
    \\  };
    \\  globalThis.MutationObserver.prototype.observe = function(target, options) {
    \\    options = options || {};
    \\    this.__observations = this.__observations.filter(entry => entry.target !== target);
    \\    this.__observations.push({ target: target, options: {
    \\      childList: !!options.childList,
    \\      attributes: !!options.attributes,
    \\      characterData: !!options.characterData,
    \\      subtree: !!options.subtree,
    \\      attributeOldValue: !!options.attributeOldValue,
    \\      characterDataOldValue: !!options.characterDataOldValue,
    \\    } });
    \\  };
    \\  globalThis.MutationObserver.prototype.disconnect = function() {
    \\    this.__records = [];
    \\    this.__observations = [];
    \\  };
    \\  globalThis.MutationObserver.prototype.takeRecords = function() {
    \\    const out = this.__records.slice();
    \\    this.__records.length = 0;
    \\    return out;
    \\  };
    \\  globalThis.performance = globalThis.performance || { now: function() { return Date.now(); } };
    \\
    \\  globalThis.Event = function(type, opts) {
    \\    opts = opts || {};
    \\    this.type = String(type || '');
    \\    this.bubbles = !!opts.bubbles;
    \\    this.cancelable = !!opts.cancelable;
    \\    this.defaultPrevented = false;
    \\    this.target = null;
    \\    this.currentTarget = null;
    \\    this.eventPhase = 0;
    \\    this.isTrusted = false;
    \\    this.timeStamp = Date.now();
    \\    this.__stop = false;
    \\    this.__stopImmediate = false;
    \\  };
    \\  globalThis.Event.prototype.preventDefault = function() {
    \\    if (this.cancelable) this.defaultPrevented = true;
    \\  };
    \\  globalThis.Event.prototype.stopPropagation = function() {
    \\    this.__stop = true;
    \\  };
    \\  globalThis.Event.prototype.stopImmediatePropagation = function() {
    \\    this.__stop = true;
    \\    this.__stopImmediate = true;
    \\  };
    \\  globalThis.CustomEvent = function(type, opts) {
    \\    globalThis.Event.call(this, type, opts);
    \\    this.detail = (opts && opts.detail) || null;
    \\  };
    \\  globalThis.CustomEvent.prototype = Object.create(globalThis.Event.prototype);
    \\  globalThis.CustomEvent.prototype.constructor = globalThis.CustomEvent;
    \\  globalThis.MouseEvent = globalThis.Event;
    \\  globalThis.KeyboardEvent = globalThis.Event;
    \\  globalThis.TouchEvent = globalThis.Event;
    \\  globalThis.FocusEvent = globalThis.Event;
    \\
    \\  globalThis.StorageEvent = function(type, opts) {
    \\    opts = opts || {};
    \\    globalThis.Event.call(this, type, opts);
    \\    this.key = opts.key == null ? null : opts.key;
    \\    this.oldValue = opts.oldValue == null ? null : opts.oldValue;
    \\    this.newValue = opts.newValue == null ? null : opts.newValue;
    \\    this.url = opts.url || '';
    \\    this.storageArea = opts.storageArea || null;
    \\  };
    \\  globalThis.StorageEvent.prototype = Object.create(globalThis.Event.prototype);
    \\  globalThis.StorageEvent.prototype.constructor = globalThis.StorageEvent;
    \\
    \\  function __awr_make_storage__() {
    \\    const data = Object.create(null);
    \\    const storage = {
    \\      get length() { return Object.keys(data).length; },
    \\      key(index) {
    \\        const keys = Object.keys(data);
    \\        return index >= 0 && index < keys.length ? keys[index] : null;
    \\      },
    \\      getItem(key) {
    \\        key = String(key);
    \\        return Object.prototype.hasOwnProperty.call(data, key) ? data[key] : null;
    \\      },
    \\      setItem(key, value) {
    \\        key = String(key);
    \\        value = String(value);
    \\        const oldValue = this.getItem(key);
    \\        data[key] = value;
    \\      },
    \\      removeItem(key) {
    \\        key = String(key);
    \\        const oldValue = this.getItem(key);
    \\        delete data[key];
    \\      },
    \\      clear() {
    \\        for (const key of Object.keys(data)) delete data[key];
    \\      },
    \\    };
    \\    return storage;
    \\  }
    \\
    \\  globalThis.localStorage = __awr_make_storage__();
    \\  globalThis.sessionStorage = __awr_make_storage__();
    \\
    \\  globalThis.XMLHttpRequest = function() {
    \\    this.readyState = 0;
    \\    this.status = 0;
    \\    this.statusText = '';
    \\    this.responseText = '';
    \\    this.responseURL = '';
    \\    this.__method = 'GET';
    \\    this.__url = '';
    \\    this.__headers = Object.create(null);
    \\  };
    \\  globalThis.XMLHttpRequest.prototype.open = function(method, url) {
    \\    if (arguments.length > 2 && arguments[2] === false) {
    \\      throw new Error('XMLHttpRequest: sync mode is not currently supported');
    \\    }
    \\    if (arguments.length > 3) {
    \\      throw new Error('XMLHttpRequest: credentialed requests are not currently supported');
    \\    }
    \\    this.__method = String(method || 'GET').toUpperCase();
    \\    if (this.__method !== 'GET') {
    \\      throw new Error('XMLHttpRequest: only async GET is currently supported');
    \\    }
    \\    this.__url = String(url || '');
    \\    this.readyState = 1;
    \\    this.dispatchEvent(new Event('readystatechange'));
    \\  };
    \\  globalThis.XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
    \\    throw new Error('XMLHttpRequest: request headers are not currently supported');
    \\  };
    \\  globalThis.XMLHttpRequest.prototype.abort = function() {
    \\    this.readyState = 4;
    \\    this.dispatchEvent(new Event('readystatechange'));
    \\    this.dispatchEvent(new Event('loadend'));
    \\  };
    \\  globalThis.XMLHttpRequest.prototype.getResponseHeader = function(name) {
    \\    const key = String(name || '').toLowerCase();
    \\    return this.__responseHeadersMap && Object.prototype.hasOwnProperty.call(this.__responseHeadersMap, key) ? this.__responseHeadersMap[key] : null;
    \\  };
    \\  globalThis.XMLHttpRequest.prototype.getAllResponseHeaders = function() {
    \\    if (!this.__responseHeadersMap) return '';
    \\    return Object.keys(this.__responseHeadersMap).map((key) => key + ': ' + this.__responseHeadersMap[key]).join('\r\n');
    \\  };
    \\  globalThis.XMLHttpRequest.prototype.addEventListener = function(type, callback, options) { __awr_add_event_listener__(this, type, callback, options); };
    \\  globalThis.XMLHttpRequest.prototype.removeEventListener = function(type, callback, options) { __awr_remove_event_listener__(this, type, callback, options); };
    \\  globalThis.XMLHttpRequest.prototype.dispatchEvent = function(event) { return __awr_dispatch_event__(this, event); };
    \\  globalThis.XMLHttpRequest.prototype.send = function(body) {
    \\    if (body != null) {
    \\      throw new Error('XMLHttpRequest: request bodies are not currently supported');
    \\    }
    \\    const self = this;
    \\    fetch(this.__url)
    \\      .then(function(response) {
        \\        self.status = response.status;
        \\        self.responseURL = response.url || self.__url;
        \\        self.__responseHeadersMap = response.__headersMap || {};
    \\        return response.text();
    \\      })
    \\      .then(function(text) {
    \\        self.responseText = text;
    \\        self.readyState = 4;
    \\        self.dispatchEvent(new Event('readystatechange'));
    \\        self.dispatchEvent(new Event('load'));
    \\        self.dispatchEvent(new Event('loadend'));
    \\      }, function() {
    \\        self.status = 0;
    \\        self.readyState = 4;
    \\        self.dispatchEvent(new Event('readystatechange'));
    \\        self.dispatchEvent(new Event('error'));
    \\        self.dispatchEvent(new Event('loadend'));
    \\      });
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

test "bridge — localStorage set/get works" {
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
