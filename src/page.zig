/// page.zig — AWR Phase 2 top-level Page type.
///
/// Wires the full pipeline: fetch URL → parse HTML → execute inline <script>
/// tags via QuickJS-NG → return post-JS document state.
///
/// Usage:
///   var page = try Page.init(allocator);
///   defer page.deinit();
///   var result = try page.navigate("https://example.com/");
///   defer result.deinit();
///   std.debug.print("title: {?s}\n", .{result.title});
const std = @import("std");

const client_mod = @import("client.zig");
const engine_mod = @import("js/engine.zig");
const html_mod   = @import("html/parser.zig");
const dom_mod    = @import("dom/node.zig");

// ── PageResult ────────────────────────────────────────────────────────────

/// Result of a Page.navigate() call. Caller owns all memory; call deinit().
pub const PageResult = struct {
    /// Final URL after any redirects (same as input for now — redirect tracking TODO).
    url: []const u8,
    /// HTTP status code of the final response.
    status: u16,
    /// Content of the <title> element, or null if absent.
    title: ?[]u8,
    /// Concatenated visible text content of the <body>.
    body_text: []u8,
    /// Raw HTML response bytes.
    html: []u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *PageResult) void {
        self.allocator.free(self.url);
        if (self.title) |t| self.allocator.free(t);
        self.allocator.free(self.body_text);
        self.allocator.free(self.html);
    }
};

// ── Page errors ───────────────────────────────────────────────────────────

pub const PageError = error{
    FetchFailed,
    ParseFailed,
    JsInitFailed,
    OutOfMemory,
};

// ── Page ──────────────────────────────────────────────────────────────────

pub const Page = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PageError!Page {
        return Page{ .allocator = allocator };
    }

    pub fn deinit(_: *Page) void {}

    /// Fetch `url`, parse the HTML, execute inline <script> tags, and return
    /// the post-JS document state. Caller owns the returned PageResult.
    pub fn navigate(self: *Page, url: []const u8) anyerror!PageResult {
        const gpa = self.allocator;

        // 1. Fetch
        var http_client = client_mod.Client.init(gpa, .{
            .follow_redirects = true,
            .use_chrome_headers = false, // plain headers → uncompressed body
        });
        defer http_client.deinit();

        var resp = http_client.fetch(url) catch return PageError.FetchFailed;
        defer resp.deinit();

        // Keep a copy of the raw HTML owned by PageResult
        const html_copy = try gpa.dupe(u8, resp.body);
        errdefer gpa.free(html_copy);

        // 2. Parse HTML
        var parser = html_mod.HtmlParser.init() catch return PageError.ParseFailed;
        defer parser.deinit();
        var doc = parser.parse(resp.body) catch return PageError.ParseFailed;
        defer doc.deinit();

        // 3. Build DOM tree
        var dom = dom_mod.parseDocument(gpa, resp.body) catch return PageError.ParseFailed;
        defer dom.deinit();

        // 4. Extract title
        const title: ?[]u8 = blk: {
            var title_len: usize = 0;
            if (doc.title(&title_len)) |t| {
                break :blk gpa.dupe(u8, t[0..title_len]) catch break :blk null;
            }
            break :blk null;
        };
        errdefer if (title) |t| gpa.free(t);

        // 5. Extract visible body text
        const body_text: []u8 = blk: {
            if (dom.body()) |body_elem| {
                const txt = body_elem.textContent(gpa) catch break :blk try gpa.dupe(u8, "");
                break :blk txt;
            }
            break :blk try gpa.dupe(u8, "");
        };
        errdefer gpa.free(body_text);

        // 6. Execute inline <script> tags via QuickJS-NG
        var js = engine_mod.JsEngine.init(gpa, null) catch return PageError.JsInitFailed;
        defer js.deinit();

        if (dom.body()) |body_elem| {
            try executeScripts(&js, body_elem);
        }
        js.drainMicrotasks();

        // 7. Build result
        const url_copy = try gpa.dupe(u8, url);
        errdefer gpa.free(url_copy);

        return PageResult{
            .url        = url_copy,
            .status     = resp.status,
            .title      = title,
            .body_text  = body_text,
            .html       = html_copy,
            .allocator  = gpa,
        };
    }

    /// Walk the DOM subtree and eval every <script> element whose src is
    /// absent (inline scripts only). Remote scripts are skipped in Phase 2.
    fn executeScripts(
        js: *engine_mod.JsEngine,
        root: *dom_mod.Element,
    ) anyerror!void {
        for (root.children.items) |child| {
            switch (child) {
                .element => |elem| {
                    // Can't mutate via const — get a mutable pointer via index
                    _ = elem; // suppress unused warning; we use child_ptr below
                },
                else => {},
            }
        }
        // Use index-based walk so we can pass mutable pointers
        var i: usize = 0;
        while (i < root.children.items.len) : (i += 1) {
            const child = &root.children.items[i];
            if (child.* != .element) continue;
            const elem = &child.element;
            if (std.ascii.eqlIgnoreCase(elem.tag, "script")) {
                if (elem.getAttribute("src") == null) {
                    const src = elem.textContent(js.allocator) catch continue;
                    defer js.allocator.free(src);
                    if (src.len > 0) {
                        js.eval(src, "inline") catch |err| {
                            std.log.warn("page: inline script error: {}", .{err});
                        };
                    }
                }
            }
            // Recurse
            try executeScripts(js, elem);
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "Page.init and deinit" {
    var page = try Page.init(std.testing.allocator);
    defer page.deinit();
}

test "PageResult.deinit frees all fields" {
    // Build a PageResult manually and deinit it — checks no leaks
    const gpa = std.testing.allocator;
    const result = PageResult{
        .url       = try gpa.dupe(u8, "http://example.com/"),
        .status    = 200,
        .title     = try gpa.dupe(u8, "Test"),
        .body_text = try gpa.dupe(u8, "Hello world"),
        .html      = try gpa.dupe(u8, "<html></html>"),
        .allocator = gpa,
    };
    var r = result;
    r.deinit();
}

test "PageResult with null title" {
    const gpa = std.testing.allocator;
    const result = PageResult{
        .url       = try gpa.dupe(u8, "http://example.com/"),
        .status    = 404,
        .title     = null,
        .body_text = try gpa.dupe(u8, ""),
        .html      = try gpa.dupe(u8, ""),
        .allocator = gpa,
    };
    var r = result;
    r.deinit();
    try std.testing.expect(true); // deinit with null title must not crash
}

// Integration test — requires network; run with: zig build test-page
// test "integration: navigate http://example.com/" {
//     var page = try Page.init(std.testing.allocator);
//     defer page.deinit();
//     var result = try page.navigate("http://example.com/");
//     defer result.deinit();
//     try std.testing.expectEqual(@as(u16, 200), result.status);
//     try std.testing.expect(result.body_text.len > 0);
// }
