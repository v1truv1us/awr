/// page.zig — AWR Phase 2 top-level Page type.
///
/// Wires the full pipeline:
///   Client.fetch → HtmlParser.parse → Document.fromLexbor →
///   installDomBridge → execute inline <script> tags →
///   drainMicrotasks → extract title + body_text → PageResult
///
/// Usage:
///   var page = try Page.init(allocator);
///   defer page.deinit();
///   var result = try page.navigate("http://example.com/");
///   defer result.deinit();
///   std.debug.print("title: {?s}\n", .{result.title});
const std    = @import("std");
const client = @import("client.zig");
const engine = @import("js/engine.zig");
const dom    = @import("dom/node.zig");   // parseDocument handles HTML+DOM internally
const bridge = @import("dom/bridge.zig");

// ── PageResult ────────────────────────────────────────────────────────────

/// Result of a Page.navigate() or Page.processHtml() call.
/// All fields are owned by this struct; call deinit() when done.
pub const PageResult = struct {
    /// The URL that was requested.
    url: []const u8,
    /// HTTP status code of the final response.
    status: u16,
    /// Content of the <title> element, or null if absent.
    title: ?[]const u8,
    /// Concatenated visible text content of <body>.
    body_text: []const u8,
    /// Full raw HTML response bytes.
    html: []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *PageResult) void {
        self.allocator.free(self.url);
        if (self.title) |t| self.allocator.free(t);
        self.allocator.free(self.body_text);
        self.allocator.free(self.html);
    }
};

// ── Page ──────────────────────────────────────────────────────────────────

/// Top-level browser page.  Owns an HTTP client and a JS engine.
///
/// The JS engine context persists across navigations; variables set by
/// scripts in one navigation remain visible in subsequent ones.
/// Phase 3 will add per-navigation context resets.
pub const Page = struct {
    allocator: std.mem.Allocator,
    client:    client.Client,
    js:        engine.JsEngine,

    /// Initialise a new Page with default client options.
    pub fn init(allocator: std.mem.Allocator) !Page {
        var js_engine = try engine.JsEngine.init(allocator, null);
        errdefer js_engine.deinit();
        return Page{
            .allocator = allocator,
            .client    = client.Client.init(allocator, .{
                .use_chrome_headers = false, // plain headers → uncompressed body
            }),
            .js = js_engine,
        };
    }

    pub fn deinit(self: *Page) void {
        self.js.deinit();
        self.client.deinit();
    }

    // ── Public API ───────────────────────────────────────────────────────

    /// Fetch `url`, parse the HTML, execute inline <script> tags, and return
    /// the post-JS document state.  Caller must call result.deinit().
    pub fn navigate(self: *Page, url: []const u8) !PageResult {
        var resp = try self.client.fetch(url);
        defer resp.deinit();
        return self.processHtml(url, resp.status, resp.body);
    }

    /// Process an already-fetched HTML string without making a network
    /// request.  Useful for unit tests and offline scenarios.
    /// Caller must call result.deinit().
    pub fn processHtml(
        self:     *Page,
        url:      []const u8,
        status:   u16,
        html_src: []const u8,
    ) !PageResult {
        const gpa = self.allocator;

        // Keep a copy of the raw HTML for PageResult.html.
        const html = try gpa.dupe(u8, html_src);
        errdefer gpa.free(html);

        // ── Parse HTML + build Zig DOM in one step ────────────────────────
        // dom.parseDocument keeps everything within a single @cImport context,
        // avoiding the cross-module cImport type-mismatch that arises when
        // html/parser.zig and dom/node.zig are imported separately.
        var zig_doc = try dom.parseDocument(gpa, html);
        defer zig_doc.deinit();

        // ── Install DOM bridge (document/window globals in JS) ────────────
        // removeDomBridge runs before zig_doc.deinit (LIFO defer order).
        try bridge.installDomBridge(&self.js, &zig_doc, gpa);
        defer bridge.removeDomBridge(&self.js);

        // ── Execute inline <script> tags in document order ────────────────
        if (zig_doc.htmlElement()) |root| self.executeScriptsInElement(root);

        // ── Drain microtask / Promise queue ───────────────────────────────
        self.js.drainMicrotasks();

        // ── Extract title ─────────────────────────────────────────────────
        const title: ?[]const u8 = blk: {
            const head = zig_doc.head() orelse break :blk null;
            const title_elem = head.firstChildByTag("title") orelse break :blk null;
            const text = title_elem.textContent(gpa) catch break :blk null;
            if (text.len == 0) { gpa.free(text); break :blk null; }
            break :blk text;
        };
        errdefer if (title) |t| gpa.free(t);

        // ── Extract body text ─────────────────────────────────────────────
        const body_text: []const u8 = blk: {
            const body = zig_doc.body() orelse break :blk try gpa.dupe(u8, "");
            break :blk body.textContent(gpa) catch try gpa.dupe(u8, "");
        };
        errdefer gpa.free(body_text);

        const url_copy = try gpa.dupe(u8, url);

        return PageResult{
            .url       = url_copy,
            .status    = status,
            .title     = title,
            .body_text = body_text,
            .html      = html,
            .allocator = gpa,
        };
    }

    // ── Script execution ─────────────────────────────────────────────────

    /// Walk the DOM subtree depth-first and eval each inline <script> in
    /// document order.  External scripts (src=) are skipped — Phase 3.
    fn executeScriptsInElement(self: *Page, elem: *const dom.Element) void {
        if (std.ascii.eqlIgnoreCase(elem.tag, "script")) {
            if (elem.getAttribute("src") == null) {
                const src = elem.textContent(self.allocator) catch return;
                defer self.allocator.free(src);
                const trimmed = std.mem.trim(u8, src, " \t\r\n");
                if (trimmed.len > 0) {
                    // Silently ignore JS exceptions — consistent with browser
                    // error semantics (script errors don't halt page loading).
                    self.js.eval(trimmed, "<inline-script>") catch {};
                }
            }
            return; // never recurse into <script> contents
        }
        for (elem.children.items) |child| {
            if (child == .element) self.executeScriptsInElement(child.element);
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "Page.init and deinit" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
}

test "Page.processHtml — preserves status code" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.processHtml("http://example.com/", 200,
        "<html><body></body></html>");
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 200), result.status);
}

test "Page.processHtml — preserves URL" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.processHtml("http://example.com/page", 200,
        "<html><body></body></html>");
    defer result.deinit();
    try std.testing.expectEqualStrings("http://example.com/page", result.url);
}

test "Page.processHtml — extracts title" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.processHtml("http://example.com/", 200,
        "<html><head><title>Hello AWR</title></head><body></body></html>");
    defer result.deinit();
    try std.testing.expect(result.title != null);
    try std.testing.expectEqualStrings("Hello AWR", result.title.?);
}

test "Page.processHtml — null title when <title> absent" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.processHtml("http://example.com/", 200,
        "<html><body><p>no title here</p></body></html>");
    defer result.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), result.title);
}

test "Page.processHtml — extracts body text" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.processHtml("http://example.com/", 200,
        "<html><body><p>Hello World</p></body></html>");
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result.body_text, "Hello World") != null);
}

test "Page.processHtml — html field is raw source" {
    const src = "<html><head><title>T</title></head><body></body></html>";
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.processHtml("http://example.com/", 200, src);
    defer result.deinit();
    try std.testing.expectEqualStrings(src, result.html);
}

test "Page.processHtml — executes inline script, JS state persists" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.processHtml("http://example.com/", 200,
        "<html><body><script>var __awr_x__ = 42;</script></body></html>");
    defer result.deinit();
    // JS engine persists after processHtml — variable should be visible.
    const ok = try page.js.evalBool("__awr_x__ === 42");
    try std.testing.expect(ok);
}

test "Page.processHtml — document.title accessible inside script" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.processHtml("http://example.com/", 200,
        "<html><head><title>My Page</title></head><body>" ++
        "<script>var __awr_title__ = document.title;</script>" ++
        "</body></html>");
    defer result.deinit();
    const ok = try page.js.evalBool("__awr_title__ === 'My Page'");
    try std.testing.expect(ok);
}

test "Page.processHtml — empty body gives empty body_text" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.processHtml("http://example.com/", 200,
        "<html><body></body></html>");
    defer result.deinit();
    const trimmed = std.mem.trim(u8, result.body_text, " \t\r\n");
    try std.testing.expectEqual(@as(usize, 0), trimmed.len);
}

test "Page.processHtml — external script (src=) is skipped without crash" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.processHtml("http://example.com/", 200,
        "<html><body><script src=\"/app.js\">fallback</script></body></html>");
    defer result.deinit();
    // Should complete without error even though src= script cannot be loaded.
    try std.testing.expectEqual(@as(u16, 200), result.status);
}

// ── Integration test (requires network) ───────────────────────────────────

test "Page.navigate — fetches http://example.com" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
    var result = try page.navigate("http://example.com/");
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 200), result.status);
    try std.testing.expect(result.title != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body_text, "Example Domain") != null);
}
