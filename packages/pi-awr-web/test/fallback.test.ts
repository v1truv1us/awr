import { describe, expect, test } from "bun:test";

import { htmlToFallbackPage, serializeCallArgs } from "../src/fallback";

describe("htmlToFallbackPage", () => {
  test("extracts title and readable text while ignoring scripts and styles", () => {
    const page = htmlToFallbackPage(`<!doctype html>
      <html>
        <head>
          <title>Shop &amp; Demo</title>
          <style>.hidden { display: none; }</style>
        </head>
        <body>
          <h1>Catalog</h1>
          <p>Widget&nbsp;A</p>
          <script>window.secret = true;</script>
        </body>
      </html>`);

    expect(page.title).toBe("Shop & Demo");
    expect(page.bodyText).toContain("Catalog");
    expect(page.bodyText).toContain("Widget A");
    expect(page.bodyText).not.toContain("window.secret");
    expect(page.bodyText).not.toContain("display: none");
  });
});

describe("serializeCallArgs", () => {
  test("uses an empty object when args are omitted", () => {
    expect(serializeCallArgs(undefined)).toBe("{}");
  });

  test("serializes JSON-safe objects", () => {
    expect(serializeCallArgs({ q: "Widget", qty: 2 })).toBe('{"q":"Widget","qty":2}');
  });
});
