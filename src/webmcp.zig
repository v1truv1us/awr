const std = @import("std");
const engine = @import("js/engine.zig");

pub fn install(js: *engine.JsEngine) engine.JsError!void {
    try js.eval(WEBMCP_POLYFILL, "<webmcp>");
}

pub fn getToolsJson(js: *engine.JsEngine) engine.JsError![]u8 {
    return js.evalString(
        \\(function() {
        \\  const mc = globalThis.navigator && globalThis.navigator.modelContext;
        \\  return JSON.stringify(mc ? mc.getTools() : []);
        \\})()
    );
}

pub fn callToolJson(
    js: *engine.JsEngine,
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    input_json: ?[]const u8,
) engine.JsError![]u8 {
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(allocator);

    try script.appendSlice(
        allocator,
        "globalThis.__awrWebMcpResult__ = null;" ++
            "globalThis.__awrWebMcpError__ = null;" ++
            "(function(){const mc=globalThis.navigator&&globalThis.navigator.modelContext;" ++
            "if(!mc){globalThis.__awrWebMcpError__='navigator.modelContext is not installed';return;}" ++
            "const input=",
    );
    if (input_json) |json| {
        try script.appendSlice(allocator, "JSON.parse(");
        try appendJsStr(&script, allocator, json);
        try script.appendSlice(allocator, ")");
    } else {
        try script.appendSlice(allocator, "null");
    }
    try script.appendSlice(allocator, ";Promise.resolve(mc.callTool(");
    try appendJsStr(&script, allocator, tool_name);
    try script.appendSlice(
        allocator,
        ",input)).then(function(value){globalThis.__awrWebMcpResult__=value===undefined?null:value;globalThis.__awrWebMcpError__=null;}," ++
            "function(err){globalThis.__awrWebMcpResult__=null;globalThis.__awrWebMcpError__=String((err&&err.message)||err);});})();",
    );

    try js.eval(script.items, "<webmcp-call>");
    js.drainMicrotasks();
    return js.evalString(
        \\(function() {
        \\  if (globalThis.__awrWebMcpError__ != null) throw new Error(globalThis.__awrWebMcpError__);
        \\  return JSON.stringify(globalThis.__awrWebMcpResult__);
        \\})()
    );
}

fn appendJsStr(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try list.append(alloc, '\'');
    for (s) |c| {
        switch (c) {
            '\'' => try list.appendSlice(alloc, "\\'"),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => try list.append(alloc, c),
        }
    }
    try list.append(alloc, '\'');
}

const WEBMCP_POLYFILL =
    \\(function() {
    \\  'use strict';
    \\  if (!globalThis.navigator) globalThis.navigator = {};
    \\
    \\  const registry = [];
    \\
    \\  function toMeta(tool) {
    \\    return {
    \\      name: String(tool.name),
    \\      description: tool.description == null ? '' : String(tool.description),
    \\      inputSchema: tool.inputSchema == null ? null : JSON.parse(JSON.stringify(tool.inputSchema)),
    \\    };
    \\  }
    \\
    \\  navigator.modelContext = {
    \\    registerTool(tool) {
    \\      if (!tool || typeof tool !== 'object') throw new TypeError('tool must be an object');
    \\      if (!tool.name) throw new TypeError('tool.name is required');
    \\      if (typeof tool.handler !== 'function') throw new TypeError('tool.handler must be a function');
    \\      const entry = {
    \\        name: String(tool.name),
    \\        description: tool.description == null ? '' : String(tool.description),
    \\        inputSchema: tool.inputSchema == null ? null : JSON.parse(JSON.stringify(tool.inputSchema)),
    \\        handler: tool.handler,
    \\      };
    \\      const existing = registry.findIndex((candidate) => candidate.name === entry.name);
    \\      if (existing >= 0) registry.splice(existing, 1, entry);
    \\      else registry.push(entry);
    \\      return toMeta(entry);
    \\    },
    \\    getTools() {
    \\      return registry.map(toMeta);
    \\    },
    \\    callTool(name, input) {
    \\      const tool = registry.find((candidate) => candidate.name === String(name));
    \\      if (!tool) throw new Error('WebMCP tool not found: ' + String(name));
    \\      return tool.handler(input);
    \\    },
    \\  };
    \\})()
;

test "webmcp registers metadata and calls sync handler" {
    var js = try engine.JsEngine.init(std.testing.allocator, null);
    defer js.deinit();

    try install(&js);
    try js.eval(
        \\navigator.modelContext.registerTool({
        \\  name: 'sum',
        \\  description: 'Adds numbers',
        \\  inputSchema: { type: 'object' },
        \\  handler(input) { return { total: input.a + input.b }; },
        \\});
    , "<test>");

    const tools = try getToolsJson(&js);
    defer std.testing.allocator.free(tools);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"sum\",\"description\":\"Adds numbers\",\"inputSchema\":{\"type\":\"object\"}}]",
        tools,
    );

    const result = try callToolJson(&js, std.testing.allocator, "sum", "{\"a\":2,\"b\":5}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"total\":7}", result);
}

test "webmcp resolves promise-returning handler" {
    var js = try engine.JsEngine.init(std.testing.allocator, null);
    defer js.deinit();

    try install(&js);
    try js.eval(
        \\navigator.modelContext.registerTool({
        \\  name: 'async-tool',
        \\  description: 'Async tool',
        \\  inputSchema: null,
        \\  handler(input) { return Promise.resolve({ ok: true, value: input.value }); },
        \\});
    , "<test>");

    const result = try callToolJson(&js, std.testing.allocator, "async-tool", "{\"value\":42}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"ok\":true,\"value\":42}", result);
}
