const std = @import("std");
const page_mod = @import("page");

const testharness_shim = @embedFile("wpt/testharness_shim.js");

/// Port for the in-process POST echo server fixture. Hard-coded contract
/// shared with `tests/wpt/{fetch,xhr}_post_*.js`. Do not change without
/// updating those JS test files in lockstep.
const echo_server_port: u16 = 18488;
const echo_server_host = "127.0.0.1";

const WptCase = struct {
    filename: []const u8,
    html: []const u8,
    script: []const u8,
    url: []const u8 = "http://example.com/",
};

/// In-process HTTP/1.1 echo server used by the curated POST WPT cases.
/// Listens on 127.0.0.1:18488 and replies `200 text/plain` with body
/// `"{METHOD}|{REQUEST_BODY}"` so JS can round-trip-assert that fetch/XHR
/// transmitted the right method and bytes through `std.http.Client`.
const EchoServer = struct {
    addr: std.Io.net.IpAddress,
    ready: std.Io.Semaphore = .{},
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: std.Thread = undefined,
    allocator: std.mem.Allocator = undefined,

    fn start(self: *EchoServer, allocator: std.mem.Allocator) !void {
        self.* = .{
            .addr = try std.Io.net.IpAddress.parseIp4(echo_server_host, echo_server_port),
            .allocator = allocator,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        self.ready.waitUncancelable(std.testing.io);
    }

    fn shutdown(self: *EchoServer) void {
        self.stop_flag.store(true, .release);
        // Wake the blocked `accept()` by connecting once.
        if (std.Io.net.IpAddress.connect(&self.addr, std.testing.io, .{ .mode = .stream })) |stream| {
            var s = stream;
            s.close(std.testing.io);
        } else |_| {}
        self.thread.join();
    }

    fn serve(self: *EchoServer) void {
        var listener = self.addr.listen(std.testing.io, .{ .reuse_address = true }) catch return;
        defer listener.deinit(std.testing.io);
        self.ready.post(std.testing.io);
        while (!self.stop_flag.load(.acquire)) {
            var stream = listener.accept(std.testing.io) catch continue;
            defer stream.close(std.testing.io);
            if (self.stop_flag.load(.acquire)) return;
            handleConnection(self.allocator, &stream) catch {};
        }
    }

    fn handleConnection(allocator: std.mem.Allocator, stream: *std.Io.net.Stream) !void {
        var read_storage: [16 * 1024]u8 = undefined;
        var write_storage: [8 * 1024]u8 = undefined;
        var net_reader = stream.reader(std.testing.io, &read_storage);
        var net_writer = stream.writer(std.testing.io, &write_storage);

        var http_server: std.http.Server = .init(&net_reader.interface, &net_writer.interface);
        var request = http_server.receiveHead() catch return;

        var body_buf: [4 * 1024]u8 = undefined;
        const body_reader = request.readerExpectContinue(&body_buf) catch return;
        const body = body_reader.allocRemaining(allocator, .limited(64 * 1024)) catch
            try allocator.dupe(u8, "");
        defer allocator.free(body);

        const method = @tagName(request.head.method);
        const payload = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ method, body });
        defer allocator.free(payload);

        try request.respond(payload, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
            },
        });
    }
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
    .{
        .filename = "form_input_value_type.js",
        .html = "<html><body><form id=\"f1\"><input id=\"name\" name=\"username\" type=\"text\" value=\"Alice\" placeholder=\"Enter name\" required /><input id=\"pw\" name=\"pw\" type=\"password\" /><input id=\"cb\" name=\"agree\" type=\"checkbox\" /><input id=\"hidden\" name=\"token\" type=\"hidden\" value=\"tok123\" /><input id=\"submit\" name=\"go\" type=\"submit\" value=\"Send\" /></form></body></html>",
        .script = @embedFile("wpt/form_input_value_type.js"),
    },
    .{
        .filename = "form_textarea_value.js",
        .html = "<html><body><textarea id=\"comment\" name=\"comment\" placeholder=\"Write here\">Hello world</textarea><textarea id=\"crlf\">a\r\nb\rc\n</textarea></body></html>",
        .script = @embedFile("wpt/form_textarea_value.js"),
    },
    .{
        .filename = "form_document_forms.js",
        .html = "<html><body><form id=\"form1\" action=\"/submit\" method=\"post\"><input name=\"x\" /></form><form id=\"form2\" action=\"/search\"><input name=\"q\" /></form></body></html>",
        .script = @embedFile("wpt/form_document_forms.js"),
    },
    .{
        .filename = "form_button_select.js",
        .html = "<html><body><form id=\"f\"><button id=\"btn\" name=\"go\" value=\"go_val\">Go</button><button id=\"reset\" type=\"reset\">Reset</button><select id=\"choice\" name=\"color\"><option value=\"r\">Red</option><option value=\"b\">Blue</option></select><input id=\"sub\" type=\"submit\" value=\"Send\" /></form></body></html>",
        .script = @embedFile("wpt/form_button_select.js"),
    },
    .{
        .filename = "fetch_post_basic.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/fetch_post_basic.js"),
        .url = "http://127.0.0.1:18488/",
    },
    .{
        .filename = "fetch_post_form_encoded.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/fetch_post_form_encoded.js"),
        .url = "http://127.0.0.1:18488/",
    },
    .{
        .filename = "xhr_post_basic.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/xhr_post_basic.js"),
        .url = "http://127.0.0.1:18488/",
    },
    .{
        .filename = "xhr_post_form_encoded.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/xhr_post_form_encoded.js"),
        .url = "http://127.0.0.1:18488/",
    },
    .{
        .filename = "form_method_post.js",
        .html = "<html><body><form id=\"f1\" method=\"post\" action=\"/submit\"><input name=\"x\" value=\"1\" /></form><form id=\"f2\" action=\"/search\"><input name=\"q\" /></form><form id=\"f3\" method=\"PoSt\" action=\"http://other.example/api\"><input name=\"y\" value=\"2\" /></form></body></html>",
        .script = @embedFile("wpt/form_method_post.js"),
        .url = "http://127.0.0.1:18488/forms",
    },
    .{
        .filename = "element_dataset.js",
        .html = "<html><body><div id=\"node\" data-kind=\"primary\" data-user-id=\"u-42\"></div></body></html>",
        .script = @embedFile("wpt/element_dataset.js"),
    },
    .{
        .filename = "document_documentElement.js",
        .html = "<html><body><p>body</p></body></html>",
        .script = @embedFile("wpt/document_documentElement.js"),
    },
    .{
        .filename = "document_visibility.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/document_visibility.js"),
    },
    .{
        .filename = "element_appendChild_dynamic.js",
        .html = "<html><body><div id=\"host\"></div><div id=\"host2\"></div></body></html>",
        .script = @embedFile("wpt/element_appendChild_dynamic.js"),
    },
    .{
        .filename = "element_removeChild.js",
        .html = "<html><body><div id=\"host\"><p id=\"a\">a</p><p id=\"b\">b</p></div></body></html>",
        .script = @embedFile("wpt/element_removeChild.js"),
    },
    .{
        .filename = "element_insertBefore.js",
        .html = "<html><body><div id=\"host\"><p id=\"first\">1</p><p id=\"second\">2</p></div></body></html>",
        .script = @embedFile("wpt/element_insertBefore.js"),
    },
    .{
        .filename = "url_search_params_basics.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/url_search_params_basics.js"),
    },
    .{
        .filename = "navigator_basics.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/navigator_basics.js"),
    },
    .{
        .filename = "window_basics.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/window_basics.js"),
    },
    .{
        .filename = "element_setAttribute_basic.js",
        .html = "<html><body><div id=\"node\"></div></body></html>",
        .script = @embedFile("wpt/element_setAttribute_basic.js"),
    },
    .{
        .filename = "event_properties.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/event_properties.js"),
    },
    .{
        .filename = "event_target_currentTarget.js",
        .html = "<html><body><div id=\"node\"></div><div id=\"parent\"><span id=\"child\"></span></div></body></html>",
        .script = @embedFile("wpt/event_target_currentTarget.js"),
    },
    .{
        .filename = "event_dispatchEvent_returns.js",
        .html = "<html><body><div id=\"node\"></div></body></html>",
        .script = @embedFile("wpt/event_dispatchEvent_returns.js"),
    },
    .{
        .filename = "event_constructors_alias.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/event_constructors_alias.js"),
    },
    .{
        .filename = "element_click_listener.js",
        .html = "<html><body><button id=\"btn\">go</button></body></html>",
        .script = @embedFile("wpt/element_click_listener.js"),
    },
    .{
        .filename = "history_state_length.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/history_state_length.js"),
    },
    .{
        .filename = "element_wrapper_identity.js",
        .html = "<html><body><div id=\"node\"></div><div id=\"host\"><span id=\"child\">x</span></div></body></html>",
        .script = @embedFile("wpt/element_wrapper_identity.js"),
    },
    .{
        .filename = "element_matches_attribute_selectors.js",
        .html = "<html><body><div id=\"node\" data-kind=\"primary\"></div></body></html>",
        .script = @embedFile("wpt/element_matches_attribute_selectors.js"),
    },
    .{
        .filename = "element_querySelectorAll_array.js",
        .html = "<html><body><p id=\"a\" class=\"match\">a</p><p id=\"b\">b</p><p id=\"c\" class=\"match\">c</p></body></html>",
        .script = @embedFile("wpt/element_querySelectorAll_array.js"),
    },
    .{
        .filename = "element_contains_relations.js",
        .html = "<html><body><div id=\"root\"><div id=\"leaf\"></div></div><div id=\"sibling\"></div></body></html>",
        .script = @embedFile("wpt/element_contains_relations.js"),
    },
    .{
        .filename = "selector_combinators.js",
        .html = "<html><body><div id=\"root\"><p id=\"a\" data-x=\"1\">A</p><p id=\"b\" data-x=\"2\">B</p><p id=\"c\" data-x=\"3\">C</p></div></body></html>",
        .script = @embedFile("wpt/selector_combinators.js"),
    },
    .{
        .filename = "element_textContent_setter.js",
        .html = "<html><body><div id=\"host\"><span>old</span><em>more</em></div></body></html>",
        .script = @embedFile("wpt/element_textContent_setter.js"),
    },
    .{
        .filename = "element_createElement_chain.js",
        .html = "<html><body><div id=\"host\"></div><div id=\"host2\"></div></body></html>",
        .script = @embedFile("wpt/element_createElement_chain.js"),
    },
    .{
        .filename = "mutation_observer_characterData.js",
        .html = "<html><body><div id=\"target\">initial</div></body></html>",
        .script = @embedFile("wpt/mutation_observer_characterData.js"),
    },
    .{
        .filename = "element_createElement_case.js",
        .html = "<html><body></body></html>",
        .script = @embedFile("wpt/element_createElement_case.js"),
    },
    .{
        .filename = "element_classList_toggle_returns.js",
        .html = "<html><body><div id=\"node\"></div></body></html>",
        .script = @embedFile("wpt/element_classList_toggle_returns.js"),
    },
    .{
        .filename = "event_listener_options.js",
        .html = "<html><body><div id=\"node\"></div></body></html>",
        .script = @embedFile("wpt/event_listener_options.js"),
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
    var echo: EchoServer = undefined;
    try echo.start(std.testing.allocator);
    defer echo.shutdown();

    for (curated_cases) |case| {
        try runCase(std.testing.allocator, case);
    }
}
