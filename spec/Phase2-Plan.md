# AWR Phase 2 Plan — Programmable Headless Page

> **Last updated:** 2026-03-23
> **Status:** ✅ COMPLETE — all 5 steps shipped, 419/419 tests passing as of 2026-03-26.

---

## What Phase 2 IS

"First usable milestone" — given a URL, AWR can fetch it, run the page's JavaScript,
and return meaningful data to a caller.  Not a TUI, not a full browser — just a
programmable headless page:

| # | Capability | State |
|---|---|---|
| 1 | Fetch a URL (HTTP + HTTPS) | ✅ done — `Client.fetch` wired |
| 2 | Parse HTML into a DOM | ✅ done — Lexbor → `dom/node.zig` |
| 3 | Execute inline `<script>` tags | ✅ done — `Page.executeScriptsInElement` |
| 4 | Expose `window`, `document`, `console` globals to JS | ✅ done — `dom/bridge.zig` polyfill |
| 5 | `document.querySelector` / `document.getElementById` from JS | ✅ done — native callbacks + polyfill |
| 6 | `setTimeout` / `Promise` execution (basic) | ✅ done — stubs + `drainMicrotasks` |
| 7 | Return page title, body text, data scripts set on `window` | ✅ done — `PageResult.window_data` surfaces `window.__awrData__` JSON |
| 8 | Integration test against a real page with inline JS | ✅ done — `Page.navigate` hits example.com; processHtml tests cover inline JS DOM reads |

### Current gap (the only thing keeping Phase 2 from "done")

`PageResult` exposes `title` and `body_text` but not arbitrary data set by page
scripts.  A script can do `window.__awrData__ = { count: 3 }` and nothing in the
public API surfaces that value without the caller resorting to `page.js.evalBool(…)`.
There is also no `JsEngine.evalString` method, so even callers who do reach into
`page.js` cannot easily extract string-typed JS values.

---

## Current Architecture (brief)

```
Page
 ├── client.Client          — HTTP/HTTPS fetch
 ├── js.JsEngine            — QuickJS-NG runtime + Web API stubs
 │    ├── console.{log,warn,error}
 │    ├── setTimeout / clearTimeout (no-op stubs)
 │    ├── setInterval / clearInterval (no-op stubs)
 │    └── fetch (rejected-Promise stub)
 └── processHtml()
      ├── dom.parseDocument()           — Lexbor HTML → Zig DOM tree
      ├── bridge.installDomBridge()     — installs document/window/navigator… globals
      ├── executeScriptsInElement()     — walks DOM, evals inline <script> tags
      ├── js.drainMicrotasks()          — flushes Promise job queue
      └── → PageResult { url, status, title, body_text, html }
```

**Key files:**
- `src/page.zig` — top-level `Page` + `PageResult`
- `src/js/engine.zig` — `JsEngine` (QuickJS wrapper + Web API stubs)
- `src/dom/node.zig` — Zig DOM tree (`Document`, `Element`, querySelector)
- `src/dom/bridge.zig` — JS↔DOM native callbacks + polyfill
- `src/client.zig` — HTTP client (Phase 1)
- `build.zig` — test steps, module wiring

---

## Atomic Steps to Complete Phase 2

Each step is independently committable.  Steps are ordered by dependency.

---

### Step 1 — `JsEngine.evalString`: extract a string value from JS

**Why first:** Steps 2 and 3 depend on it.

**What to build:**
Add a `evalString(source: []const u8) ![]u8` method to `JsEngine` that evaluates
a JS expression, coerces the result to a string via QuickJS `toCString`, and returns
a heap-allocated copy the caller must `free`.  Return `JsError.EvalException` on
exception; return `JsError.OutOfMemory` on allocation failure.

**Files to touch:**
- `src/js/engine.zig` — add `evalString` between `evalBool` and `drainMicrotasks`

**Sketch:**
```zig
pub fn evalString(self: *JsEngine, source: []const u8) JsError![]u8 {
    const result = self.ctx.eval(source, "<eval>", .{});
    defer result.deinit(self.ctx);
    if (result.isException()) return JsError.EvalException;
    const cstr = result.toCString(self.ctx) orelse return JsError.OutOfMemory;
    defer self.ctx.freeCString(cstr);
    return self.allocator.dupe(u8, std.mem.span(cstr)) catch return JsError.OutOfMemory;
}
```

**How to verify:**
```
zig build test-js --summary all
```
Assert:
- `js.evalString("'hello ' + 'world'")` returns `"hello world"`
- `js.evalString("String(42)")` returns `"42"`
- `js.evalString("throw new Error('x')")` returns `JsError.EvalException`
- Caller-freed string does not leak under ASAN / Valgrind (or `std.testing.allocator`)

**Definition of done:** `test-js` 100% pass, no allocator leaks, new method visible in
the module's public surface.

---

### Step 2 — Set `window.location.href` from the actual URL

**Why:** Scripts that guard behaviour on `location.href` (e.g. `if (location.hostname
=== 'example.com')`) currently see an empty string.  This is a 30-minute fix that
closes a class of script misbehaviours before they become test failures.

**What to build:**
After `installDomBridge` succeeds, evaluate a short JS snippet that overwrites the
stub location with the real URL values parsed from the request URL.  The simplest
correct approach is to do this in `Page.processHtml` right after the bridge is
installed, using `JsEngine.eval`.

**Files to touch:**
- `src/page.zig` — two lines after `try bridge.installDomBridge(…)`

**Sketch (in `Page.processHtml`):**
```zig
// After: try bridge.installDomBridge(&self.js, &zig_doc, gpa);
const loc_script = try std.fmt.allocPrintZ(gpa,
    \\(function(u){{
    \\  try {{
    \\    var p = new URL(u);
    \\    globalThis.location.href     = p.href;
    \\    globalThis.location.origin   = p.origin;
    \\    globalThis.location.pathname = p.pathname;
    \\    globalThis.location.search   = p.search;
    \\    globalThis.location.hash     = p.hash;
    \\    globalThis.location.hostname = p.hostname;
    \\    globalThis.location.protocol = p.protocol;
    \\  }} catch(e) {{}}
    \\}})("{s}");
, .{url});
defer gpa.free(loc_script);
self.js.eval(loc_script, "<location-init>") catch {};
```

Note: QuickJS ships with a `URL` built-in so this works without adding a polyfill.

**How to verify:**
```
zig build test-page --summary all
```
Add one new test in `src/page.zig`:
```zig
test "Page.processHtml — window.location.href matches url arg" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.processHtml(
        "https://example.com/path?q=1", 200, "<html><body></body></html>");
    defer result.deinit();
    const ok = try page.js.evalBool("window.location.href === 'https://example.com/path?q=1'");
    try std.testing.expect(ok);
}
```

**Definition of done:** the new test passes; all 147+ page tests still pass.

---

### Step 3 — Surface `window.__awrData__` in `PageResult`

**Why:** The primary use case for a headless page engine is "run the page's JS and
get data back."  Without this, callers must reach into `page.js` directly, bypassing
the clean `PageResult` API.

**What to build:**

1. Add `window_data: ?[]const u8` field to `PageResult` (JSON string or null).
2. In `Page.processHtml`, after `drainMicrotasks`, extract:
   ```js
   typeof window.__awrData__ !== 'undefined'
     ? JSON.stringify(window.__awrData__)
     : null
   ```
   using the new `evalString` (Step 1).  If the result is the string `"null"` or
   `evalString` errors, store `null`.  Store a heap copy otherwise.
3. Add `window_data` to `PageResult.deinit` cleanup.

**Files to touch:**
- `src/page.zig` — `PageResult` struct, `processHtml`, `deinit`

**Sketch (PageResult):**
```zig
pub const PageResult = struct {
    url:         []const u8,
    status:      u16,
    title:       ?[]const u8,
    body_text:   []const u8,
    html:        []const u8,
    window_data: ?[]const u8,   // ← NEW: JSON of window.__awrData__, or null
    allocator:   std.mem.Allocator,

    pub fn deinit(self: *PageResult) void {
        self.allocator.free(self.url);
        if (self.title)       |t| self.allocator.free(t);
        self.allocator.free(self.body_text);
        self.allocator.free(self.html);
        if (self.window_data) |d| self.allocator.free(d);  // ← NEW
    }
};
```

**Sketch (extraction in `processHtml`, after `drainMicrotasks`):**
```zig
const window_data: ?[]const u8 = blk: {
    const json = self.js.evalString(
        "typeof window.__awrData__!=='undefined'" ++
        " ? JSON.stringify(window.__awrData__) : 'null'"
    ) catch break :blk null;
    if (std.mem.eql(u8, json, "null")) { gpa.free(json); break :blk null; }
    break :blk json;
};
errdefer if (window_data) |d| gpa.free(d);
```

**How to verify:**
```
zig build test-page --summary all
```
Add two new tests in `src/page.zig`:
```zig
test "Page.processHtml — window.__awrData__ is surfaced in PageResult" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.processHtml("http://example.com/", 200,
        "<html><body>" ++
        "<script>window.__awrData__ = { items: [1, 2, 3], ok: true };</script>" ++
        "</body></html>");
    defer result.deinit();
    try std.testing.expect(result.window_data != null);
    // JSON must contain the expected fields (exact order not guaranteed)
    try std.testing.expect(
        std.mem.indexOf(u8, result.window_data.?, "\"ok\":true") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, result.window_data.?, "\"items\"") != null);
}

test "Page.processHtml — window_data is null when __awrData__ not set" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.processHtml("http://example.com/", 200,
        "<html><body><p>no data</p></body></html>");
    defer result.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), result.window_data);
}
```

**Definition of done:** Both new tests pass; all existing page tests still pass; no
allocator leaks.

---

### Step 4 — Integration test: real inline-JS page with DOM mutation

**Why:** Item 8 in the Phase 2 goal — verify the full pipeline against a page where
inline JS *mutates* the DOM, not just reads it, and that mutation is captured in the
callers' result.

**What to build:**
A new test in `src/page.zig` (or a separate `src/test_phase2_integration.zig` wired
to `zig build test-page`) that:

1. Uses `processHtml` with hand-crafted HTML containing a script that:
   - Reads `document.title` ✓ (already tested)
   - Calls `document.querySelector` to find an element
   - Sets `window.__awrData__` with a computed value
2. After `processHtml`, asserts `result.window_data` contains the expected JSON.

This test exercises the complete Phase 2 pipeline in a single, readable scenario
and serves as the canonical "Phase 2 smoke test."

**Files to touch:**
- `src/page.zig` — new test at the end of the test section

```zig
test "Phase 2 integration — JS reads DOM and surfaces data via window.__awrData__" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();

    var result = try page.processHtml("https://shop.example.com/", 200,
        \\<html>
        \\<head><title>Shop</title></head>
        \\<body>
        \\  <ul id="products">
        \\    <li class="product" data-price="9.99">Widget A</li>
        \\    <li class="product" data-price="19.99">Widget B</li>
        \\    <li class="product" data-price="4.99">Widget C</li>
        \\  </ul>
        \\  <script>
        \\    var items = document.querySelectorAll('.product');
        \\    var names = [];
        \\    for (var i = 0; i < items.length; i++) {
        \\      names.push(items[i].textContent);
        \\    }
        \\    window.__awrData__ = {
        \\      title:      document.title,
        \\      itemCount:  items.length,
        \\      names:      names,
        \\      url:        window.location.href,
        \\    };
        \\  </script>
        \\</body>
        \\</html>
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("Shop", result.title.?);
    try std.testing.expect(result.window_data != null);

    const wd = result.window_data.?;
    try std.testing.expect(std.mem.indexOf(u8, wd, "\"itemCount\":3")  != null);
    try std.testing.expect(std.mem.indexOf(u8, wd, "Widget A")        != null);
    try std.testing.expect(std.mem.indexOf(u8, wd, "\"title\":\"Shop\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wd, "shop.example.com") != null);
}
```

**How to verify:**
```
zig build test-page --summary all
```
The integration test passes.  All existing 147+ page tests still pass.

**Definition of done:** Test passes; `zig build test --summary all` shows
406+ tests, 0 skipped.

---

## What is Explicitly OUT of Scope for Phase 2

- Remote `<script src="…">` loading (network fetch of external JS)
- CSS parsing, cascade, or layout
- XHR / `fetch()` API (stub that rejects is sufficient)
- Firing event listeners (`click`, `scroll`, `input`, etc.)
- Full DOM spec compliance (`insertAdjacentHTML`, live `NodeList`, etc.)
- TUI / visual output or screenshot rendering
- Phase 3 TLS fingerprinting (`curl_impersonate` / BoringSSL)
- `window.location` navigation (following redirects from JS)
- Web Workers / Service Workers
- WebAssembly
- `MutationObserver` callbacks (stub that does nothing is sufficient)

---

## Phase 2 Exit Criteria

Phase 2 is **done** when ALL of the following are true:

1. `zig build test --summary all` → **0 skipped, 0 failed** (currently: 406/406 ✅)
2. `JsEngine.evalString` exists and is tested (Step 1)
3. `window.location.href` reflects the URL passed to `processHtml` / `navigate` (Step 2)
4. `PageResult.window_data` surfaces JSON set on `window.__awrData__` by page scripts (Step 3)
5. The Phase 2 integration test passes end-to-end with a multi-element DOM query (Step 4)
6. `Page.navigate("https://example.com/")` returns a non-null title and non-empty
   body text (existing test ✅)

---

## Commit Convention for Remaining Steps

```
feat(phase2): add JsEngine.evalString — extract string values from JS
feat(phase2): set window.location.href from URL in processHtml
feat(phase2): surface window.__awrData__ as PageResult.window_data
test(phase2): integration test — JS reads DOM, sets window.__awrData__
```

After the last commit, tag: `git tag v0.2.0`.
