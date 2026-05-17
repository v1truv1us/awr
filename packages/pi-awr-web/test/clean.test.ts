import { describe, expect, test } from "bun:test";

import { cleanBodyText, contentRatio } from "../src/clean";

describe("cleanBodyText", () => {
  test("returns empty string for empty input", () => {
    expect(cleanBodyText("")).toBe("");
    expect(cleanBodyText("   ")).toBe("");
  });

  test("strips boilerplate navigation lines", () => {
    const input = [
      "Jump to content",
      "Main menu",
      "Toggle navigation",
      "Sign in",
      "Search",
      "Donate",
      "Create account",
      "Log in",
      "",
      "This is real content about something interesting.",
    ].join("\n");

    const result = cleanBodyText(input);
    expect(result).toContain("real content");
    expect(result).not.toContain("Jump to");
    expect(result).not.toContain("Toggle");
    expect(result).not.toContain("Donate");
  });

  test("detects numbered link lists and separates items", () => {
    const input = [
      "Hacker Newsnew | past | comments",
      "1.Dirtyfrag: Universal LPE (openwall.com)348 points by flipped 4 hours ago",
      "2.Canvas LMS Down (theverge.com)84 points by stefanpie 3 hours ago",
      "3.Agents need control flow (bsuh.bearblog.dev)294 points by bsuh 8 hours ago",
      "More",
      "Guidelines | FAQ | Lists | API",
    ].join("\n");

    const result = cleanBodyText(input);
    expect(result).toContain("1.Dirtyfrag");
    expect(result).toContain("2.Canvas");
    expect(result).toContain("3.Agents");
    // Items should be separated by blank lines
    expect(result).toMatch(/1\.Dirtyfrag.*\n\n.*2\.Canvas/s);
  });

  test("splits flat inline numbered items (HN-style single-line body)", () => {
    const input =
      "Hacker Newsnew | past1.Dirtyfrag: Universal LPE (openwall.com)348 points2.Canvas LMS Down (theverge.com)84 points3.Agents need control flow (bsuh.bearblog.dev)294 pointsMoreGuidelines";

    const result = cleanBodyText(input);
    expect(result).toContain("1.Dirtyfrag");
    expect(result).toContain("2.Canvas");
    expect(result).toContain("3.Agents");
    expect(result).toMatch(/1\.Dirtyfrag.*\n\n.*2\.Canvas/s);
  });

  test("preserves normal prose with paragraph breaks", () => {
    const input = [
      "Zig is a system programming language.",
      "",
      "It was designed by Andrew Kelley and first announced in 2016.",
      "",
      "Features include compile-time generics and no hidden control flow.",
    ].join("\n");

    const result = cleanBodyText(input);
    expect(result).toContain("Zig is a system");
    expect(result).toContain("Andrew Kelley");
    expect(result).toContain("compile-time generics");
  });

  test("strips multi-line boilerplate blocks", () => {
    const input = [
      "Navigation Menu",
      "  Toggle navigation",
      "  Sign in",
      "  Appearance settings",
      "",
      "This is the actual article content that should be preserved.",
      "It spans multiple paragraphs and contains useful information.",
    ].join("\n");

    const result = cleanBodyText(input);
    expect(result).toContain("actual article content");
    expect(result).toContain("useful information");
  });
});

describe("contentRatio", () => {
  test("returns 1 for pure content", () => {
    const ratio = contentRatio("This is pure content without any boilerplate.");
    expect(ratio).toBeGreaterThan(0.8);
  });

  test("returns lower ratio for boilerplate-heavy text", () => {
    const input = [
      "Jump to content",
      "Toggle navigation",
      "Sign in",
      "Search",
      "Main menu",
      "Donate",
      "Create account",
      "A small bit of content.",
    ].join("\n");

    const ratio = contentRatio(input);
    expect(ratio).toBeLessThan(0.5);
  });
});
