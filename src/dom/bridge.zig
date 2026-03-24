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
    bctx.* = .{ .doc = doc, .allocator = alloc };

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
    bctx.allocator.destroy(bctx);
    host.extension = null;
}

// ── Native callbacks ──────────────────────────────────────────────────────

fn installNativeCallbacks(eng: *engine.JsEngine) !void {
    const ctx = eng.ctx;

    inline for (.{
        .{ "querySelector",    querySelectorFn },
        .{ "querySelectorAll", querySelectorAllFn },
        .{ "getElementById",   getElementByIdFn },
        .{ "getTitle",         getTitleFn },
        .{ "getBody",          getBodyFn },
    }) |entry| {
        const fname: [:0]const u8 = "__awr_" ++ entry[0] ++ "__";
        const fn_val = qjs.Value.initCFunction(ctx, entry[1], fname, 1);
        defer fn_val.deinit(ctx);
        eng.setGlobal(fname, fn_val.dup(ctx)) catch return error.PropertySetFailed;
    }
}

/// Serialize an Element to a compact JSON object string.
/// Writes into `buf`; returns the written slice or null on overflow.
fn elementToJson(elem: *const dom.Element, buf: []u8) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    w.writeAll("{\"tag\":") catch return null;
    std.json.encodeJsonString(elem.tag, .{}, w) catch return null;
    w.writeAll(",\"attrs\":[") catch return null;
    for (elem.attributes, 0..) |attr, i| {
        if (i > 0) w.writeByte(',') catch return null;
        w.writeAll("{\"name\":") catch return null;
        std.json.encodeJsonString(attr.name, .{}, w) catch return null;
        w.writeAll(",\"value\":") catch return null;
        std.json.encodeJsonString(attr.value, .{}, w) catch return null;
        w.writeByte('}') catch return null;
    }
    w.writeAll("],\"text\":") catch return null;
    // Use a temp buffer for text content
    var tbuf: [2048]u8 = undefined;
    const text = elem.textContent(std.heap.FixedBufferAllocator.init(&tbuf).allocator()) catch "";
    std.json.encodeJsonString(text, .{}, w) catch return null;
    w.writeByte('}') catch return null;

    return fbs.getWritten();
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
    const json = elementToJson(elem, &buf) orelse return qjs.Value.null;
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
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.writeByte('[') catch return qjs.Value.initStringLen(c, "[]");
    for (elems, 0..) |elem, i| {
        if (i > 0) w.writeByte(',') catch break;
        var ebuf: [8192]u8 = undefined;
        if (elementToJson(elem, &ebuf)) |json| {
            w.writeAll(json) catch break;
        }
    }
    w.writeByte(']') catch {};
    return qjs.Value.initStringLen(c, fbs.getWritten());
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
    const json = elementToJson(elem, &buf) orelse return qjs.Value.null;
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
    const json = elementToJson(body, &buf) orelse return qjs.Value.null;
    return qjs.Value.initStringLen(c, json);
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
    \\      _attrs: attrs,
    \\      _text: d.text || '',
    \\      _children: [],
    \\      getAttribute(name) { return this._attrs[name.toLowerCase()] != null ? this._attrs[name.toLowerCase()] : null; },
    \\      setAttribute(name, value) { this._attrs[name.toLowerCase()] = String(value); },
    \\      removeAttribute(name) { delete this._attrs[name.toLowerCase()]; },
    \\      hasAttribute(name) { return name.toLowerCase() in this._attrs; },
    \\      get textContent() { return this._text; },
    \\      set textContent(v) { this._text = String(v); this._innerHTML = String(v); },
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
    \\      appendChild(child) { this._children.push(child); return child; },
    \\      removeChild(child) { this._children = this._children.filter(c => c !== child); return child; },
    \\      insertBefore(node) { this._children.unshift(node); return node; },
    \\      contains(other) { return false; },
    \\      querySelector(sel) { return null; },
    \\      querySelectorAll(sel) { return []; },
    \\      matches(sel) { return false; },
    \\      closest(sel) { return null; },
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
    \\    createElement(tag) { return makeElement({tag: tag, attrs: [], text: ''}); },
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
