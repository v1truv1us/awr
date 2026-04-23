const std = @import("std");
const page_mod = @import("page");

const testharness_shim = @embedFile("wpt/testharness_shim.js");

const WptCase = struct {
    filename: []const u8,
    html: []const u8,
    script: []const u8,
};

const curated_cases = [_]WptCase{
    .{
        .filename = "document_title.js",
        .html = "<html><head><title>Harness Title</title></head><body><p>body</p></body></html>",
        .script = @embedFile("wpt/document_title.js"),
    },
    .{
        .filename = "document_getElementById.js",
        .html = "<html><body><div id=\"main\">primary</div><div id=\"secondary\">secondary</div></body></html>",
        .script = @embedFile("wpt/document_getElementById.js"),
    },
    .{
        .filename = "document_querySelector.js",
        .html = "<html><body><section id=\"hero\" class=\"banner\"><p class=\"copy\">Hello</p><p>World</p></section></body></html>",
        .script = @embedFile("wpt/document_querySelector.js"),
    },
    .{
        .filename = "document_querySelectorAll.js",
        .html = "<html><body><ul><li class=\"item\">a</li><li class=\"item\">b</li><li class=\"item\">c</li></ul></body></html>",
        .script = @embedFile("wpt/document_querySelectorAll.js"),
    },
    .{
        .filename = "descendant_selectors.js",
        .html = "<html><body><section class=\"card\"><div class=\"copy\"><p id=\"target\">hello</p></div></section><section><p id=\"other\">bye</p></section></body></html>",
        .script = @embedFile("wpt/descendant_selectors.js"),
    },
    .{
        .filename = "element_scoped_selectors.js",
        .html = "<html><body><section id=\"first\"><p class=\"item\">one</p></section><section id=\"scope\"><p class=\"item\">two</p><div><p class=\"item\">three</p></div></section></body></html>",
        .script = @embedFile("wpt/element_scoped_selectors.js"),
    },
    .{
        .filename = "element_getAttribute_textContent.js",
        .html = "<html><body><a id=\"link\" href=\"/docs\" data-kind=\"primary\">Read docs</a><div id=\"copy\">alpha<span>beta</span></div></body></html>",
        .script = @embedFile("wpt/element_getAttribute_textContent.js"),
    },
    .{
        .filename = "element_matches_closest.js",
        .html = "<html><body><section class=\"shell\"><div><p id=\"leaf\" class=\"copy\">hello</p></div></section></body></html>",
        .script = @embedFile("wpt/element_matches_closest.js"),
    },
    .{
        .filename = "console_namespace.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/console_namespace.js"),
    },
    .{
        .filename = "promise_test_basics.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/promise_test_basics.js"),
    },
    .{
        .filename = "document_title_location.js",
        .html = "<html><head><title>Harness Title</title></head><body><p>body</p></body></html>",
        .script = @embedFile("wpt/document_title_location.js"),
    },
};

fn buildCaseHtml(allocator: std.mem.Allocator, case: WptCase) ![]u8 {
    const marker = "</body>";
    if (std.mem.lastIndexOf(u8, case.html, marker)) |idx| {
        return std.fmt.allocPrint(
            allocator,
            "{s}<script>{s}</script><script>{s}</script><script>window.__awrData__ = globalThis.__wpt_results__ || [];</script>{s}",
            .{ case.html[0..idx], testharness_shim, case.script, case.html[idx..] },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}<script>{s}</script><script>{s}</script><script>window.__awrData__ = globalThis.__wpt_results__ || [];</script>",
        .{ case.html, testharness_shim, case.script },
    );
}

fn runCase(allocator: std.mem.Allocator, case: WptCase) !void {
    var page = try page_mod.Page.init(allocator, std.testing.io);
    defer page.deinit();

    const html = try buildCaseHtml(allocator, case);
    defer allocator.free(html);

    var result = try page.processHtml("http://example.com/", 200, html);
    defer result.deinit();

    const results_json = result.window_data orelse return error.WptEmpty;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, results_json, .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    if (arr.items.len == 0) return error.WptEmpty;

    for (arr.items) |item| {
        const status = item.object.get("status") orelse return error.WptMalformed;
        if (!std.mem.eql(u8, status.string, "PASS")) {
            const name = item.object.get("name") orelse return error.WptMalformed;
            const message = item.object.get("message") orelse return error.WptMalformed;
            std.debug.print("WPT case failed: {s} :: {s} :: {s}\n", .{ case.filename, name.string, message.string });
            return error.WptFailure;
        }
    }
}

test "curated WPT DOM corpus passes" {
    for (curated_cases) |case| {
        try runCase(std.testing.allocator, case);
    }
}
