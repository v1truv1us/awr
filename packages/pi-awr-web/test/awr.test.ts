import { describe, expect, test } from "bun:test";

import { buildCallArgs, buildToolsArgs, buildVisitArgs, parseCallEnvelope, parseToolsEnvelope, parseVisitEnvelope } from "../src/awr";

describe("AWR helpers", () => {
  test("builds CLI args for each action", () => {
    expect(buildVisitArgs("https://example.com")).toEqual(["https://example.com"]);
    expect(buildToolsArgs("page.html")).toEqual(["tools", "page.html"]);
    expect(buildCallArgs("page.html", "search_products", '{"q":"Widget"}')).toEqual([
      "call",
      "page.html",
      "search_products",
      '{"q":"Widget"}',
    ]);
  });

  test("parses visit output envelopes", () => {
    const parsed = parseVisitEnvelope(
      JSON.stringify({
        url: "file://page.html",
        status: 200,
        title: "Demo",
        body_text: "Hello world",
        window_data: null,
        tools: [{ name: "search_products", description: "Search" }],
      }),
    );

    expect(parsed?.title).toBe("Demo");
    expect(parsed?.tools).toHaveLength(1);
  });

  test("parses tools output envelopes", () => {
    const parsed = parseToolsEnvelope(
      JSON.stringify([{ name: "search_products", description: "Search", inputSchema: { type: "object" } }]),
    );

    expect(parsed?.[0]?.name).toBe("search_products");
  });

  test("parses call output envelopes including error envelopes", () => {
    expect(parseCallEnvelope('{"ok":true,"value":{"cart_size":1}}')).toEqual({
      ok: true,
      value: { cart_size: 1 },
    });
    expect(parseCallEnvelope('{"ok":false,"error":"ToolNotFound","message":"missing"}')).toEqual({
      ok: false,
      error: "ToolNotFound",
      message: "missing",
    });
  });
});
