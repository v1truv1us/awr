const std = @import("std");
const page_mod = @import("page");

const testharness_shim = @embedFile("wpt/testharness_shim.js");

const WptCase = struct {
    filename: []const u8,
    html: []const u8,
    script: []const u8,
    url: []const u8 = "http://example.com/",
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
        .filename = "document_body_head.js",
        .html = "<html><head><title>x</title></head><body><p>body</p></body></html>",
        .script = @embedFile("wpt/document_body_head.js"),
    },
    .{
        .filename = "document_createElement.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/document_createElement.js"),
    },
    .{
        .filename = "document_dynamic_getElementById.js",
        .html = "<html><body><div id=\"host\"></div></body></html>",
        .script = @embedFile("wpt/document_dynamic_getElementById.js"),
    },
    .{
        .filename = "document_getElementsBy.js",
        .html = "<html><body><p class=\"item\">one</p><div><p class=\"item\">two</p></div></body></html>",
        .script = @embedFile("wpt/document_getElementsBy.js"),
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
        .filename = "element_hasAttribute.js",
        .html = "<html><body><div id=\"node\" data-kind=\"primary\"></div></body></html>",
        .script = @embedFile("wpt/element_hasAttribute.js"),
    },
    .{
        .filename = "element_id_className.js",
        .html = "<html><body><div id=\"node\" class=\"initial\"></div></body></html>",
        .script = @embedFile("wpt/element_id_className.js"),
    },
    .{
        .filename = "element_matches_closest.js",
        .html = "<html><body><section class=\"shell\"><div><p id=\"leaf\" class=\"copy\">hello</p></div></section></body></html>",
        .script = @embedFile("wpt/element_matches_closest.js"),
    },
    .{
        .filename = "element_parentNode.js",
        .html = "<html><body><section id=\"shell\"><p id=\"leaf\">hello</p></section></body></html>",
        .script = @embedFile("wpt/element_parentNode.js"),
    },
    .{
        .filename = "element_siblings.js",
        .html = "<html><body><ul><li id=\"first\">a</li><li id=\"second\">b</li><li id=\"third\">c</li></ul></body></html>",
        .script = @embedFile("wpt/element_siblings.js"),
    },
    .{
        .filename = "element_classList.js",
        .html = "<html><body><div id=\"item\" class=\"foo bar\"></div></body></html>",
        .script = @embedFile("wpt/element_classList.js"),
    },
    .{
        .filename = "element_dom_getters_authoritative.js",
        .html = "<html><body><div id=\"host\"><span id=\"first\">hello</span><em id=\"last\" data-kind=\"accent\">world</em></div></body></html>",
        .script = @embedFile("wpt/element_dom_getters_authoritative.js"),
    },
    .{
        .filename = "element_innerHTML_setter.js",
        .html = "<html><body><div id=\"host\"><p id=\"old\">old</p></div></body></html>",
        .script = @embedFile("wpt/element_innerHTML_setter.js"),
    },
    .{
        .filename = "element_cloneNode.js",
        .html = "<html><body><section id=\"source\" class=\"shell\"><p class=\"copy\">hello</p></section></body></html>",
        .script = @embedFile("wpt/element_cloneNode.js"),
    },
    .{
        .filename = "element_contains.js",
        .html = "<html><body><section id=\"shell\"><p id=\"leaf\">hello</p></section></body></html>",
        .script = @embedFile("wpt/element_contains.js"),
    },
    .{
        .filename = "element_outerHTML.js",
        .html = "<html><body><div id=\"node\" data-kind=\"primary\">hello<span>world</span></div></body></html>",
        .script = @embedFile("wpt/element_outerHTML.js"),
    },
    .{
        .filename = "event_add_remove.js",
        .html = "<html><body><button id=\"btn\">press</button></body></html>",
        .script = @embedFile("wpt/event_add_remove.js"),
    },
    .{
        .filename = "event_dispatch_bubble.js",
        .html = "<html><body><div id=\"parent\"><button id=\"child\">press</button></div></body></html>",
        .script = @embedFile("wpt/event_dispatch_bubble.js"),
    },
    .{
        .filename = "event_custom.js",
        .html = "<html><body><div id=\"node\"></div></body></html>",
        .script = @embedFile("wpt/event_custom.js"),
    },
    .{
        .filename = "event_DOMContentLoaded.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/event_DOMContentLoaded.js"),
    },
    .{
        .filename = "event_prevent_default.js",
        .html = "<html><body><form id=\"node\"></form></body></html>",
        .script = @embedFile("wpt/event_prevent_default.js"),
    },
    .{
        .filename = "event_stop_propagation.js",
        .html = "<html><body><div id=\"outer\"><button id=\"inner\">press</button></div></body></html>",
        .script = @embedFile("wpt/event_stop_propagation.js"),
    },
    .{
        .filename = "element_click_focus_blur.js",
        .html = "<html><body><button id=\"node\">push</button></body></html>",
        .script = @embedFile("wpt/element_click_focus_blur.js"),
    },
    .{
        .filename = "mutation_observer_childList.js",
        .html = "<html><body><div id=\"target\"></div></body></html>",
        .script = @embedFile("wpt/mutation_observer_childList.js"),
    },
    .{
        .filename = "mutation_observer_attributes.js",
        .html = "<html><body><div id=\"target\"></div></body></html>",
        .script = @embedFile("wpt/mutation_observer_attributes.js"),
    },
    .{
        .filename = "mutation_observer_subtree.js",
        .html = "<html><body><section id=\"shell\"><div id=\"leaf\"></div></section></body></html>",
        .script = @embedFile("wpt/mutation_observer_subtree.js"),
    },
    .{
        .filename = "mutation_observer_takeRecords.js",
        .html = "<html><body><div id=\"target\"></div></body></html>",
        .script = @embedFile("wpt/mutation_observer_takeRecords.js"),
    },
    .{
        .filename = "mutation_observer_reflected_attributes.js",
        .html = "<html><body><div id=\"target\"></div></body></html>",
        .script = @embedFile("wpt/mutation_observer_reflected_attributes.js"),
    },
    .{
        .filename = "storage_localStorage.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/storage_localStorage.js"),
    },
    .{
        .filename = "session_storage_distinct.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/session_storage_distinct.js"),
    },
    .{
        .filename = "storage_event_payload.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/storage_event_payload.js"),
    },
    .{
        .filename = "xhr_basic_get.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/xhr_basic_get.js"),
        .url = "file://tests/wpt/xhr_basic.html",
    },
    .{
        .filename = "fetch_basic.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/fetch_basic.js"),
        .url = "file://tests/wpt/fetch_basic.html",
    },
    .{
        .filename = "fetch_rejects_unsupported.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/fetch_rejects_unsupported.js"),
        .url = "file://tests/wpt/fetch_rejects_unsupported.html",
    },
    .{
        .filename = "xhr_rejects_unsupported.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/xhr_rejects_unsupported.js"),
        .url = "file://tests/wpt/xhr_rejects_unsupported.html",
    },
    .{
        .filename = "viewport_dimensions.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/viewport_dimensions.js"),
    },
    .{
        .filename = "requestAnimationFrame.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/requestAnimationFrame.js"),
    },
    .{
        .filename = "request_idle_callback.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/request_idle_callback.js"),
    },
    .{
        .filename = "request_idle_callback_cancel.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/request_idle_callback_cancel.js"),
    },
    .{
        .filename = "element_bounding_client_rect.js",
        .html = "<html><body><div id=\"box\">hello world</div></body></html>",
        .script = @embedFile("wpt/element_bounding_client_rect.js"),
    },
    .{
        .filename = "history_push_replace_state.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/history_push_replace_state.js"),
    },
    .{
        .filename = "history_relative_url.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/history_relative_url.js"),
    },
    .{
        .filename = "intersection_observer.js",
        .html = "<html><body><div id=\"target\">visible</div></body></html>",
        .script = @embedFile("wpt/intersection_observer.js"),
    },
    .{
        .filename = "resize_observer.js",
        .html = "<html><body><div id=\"target\">resize me</div></body></html>",
        .script = @embedFile("wpt/resize_observer.js"),
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
    .{
        .filename = "document_title_create_missing.js",
        .html = "<html><head></head><body><p>body</p></body></html>",
        .script = @embedFile("wpt/document_title_create_missing.js"),
    },
    .{
        .filename = "document_readyState.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/document_readyState.js"),
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

    var result = try page.processHtml(case.url, 200, html);
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
