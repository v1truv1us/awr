/**
 * Integration tests — exercise the real AWR binary against local fixtures.
 *
 * These tests require a built AWR binary at the expected path.
 * They are skipped automatically when the binary is not present.
 */
import { execFile } from "node:child_process";
import { access, constants } from "node:fs/promises";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import { describe, expect, test } from "bun:test";

import { buildAwrBinaryCandidates } from "../src/config";
import { parseCallEnvelope, parseToolsEnvelope, parseVisitEnvelope } from "../src/awr";

const execFileAsync = promisify(execFile);

const PACKAGE_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const AWR_REPO_ROOT = resolve(PACKAGE_DIR, "../..");
const MOCK_FIXTURE = join(AWR_REPO_ROOT, "experiments/webmcp_mock.html");

const AWR_CANDIDATES = buildAwrBinaryCandidates(PACKAGE_DIR, process.env as Record<string, string | undefined>);

async function findAwrBinary(): Promise<string | undefined> {
  for (const candidate of AWR_CANDIDATES) {
    if (candidate.includes("/")) {
      try {
        await access(candidate, constants.X_OK);
        return candidate;
      } catch {
        continue;
      }
    }

    try {
      const { stdout } = await execFileAsync(candidate, ["--version"], { timeout: 5000 });
      if (stdout.trim().length > 0) return candidate;
    } catch {
      continue;
    }
  }

  return undefined;
}

async function runAwr(args: string[]): Promise<{ stdout: string; stderr: string; code: number }> {
  const binary = awrBinary;
  if (!binary) throw new Error("AWR binary not available");

  try {
    const { stdout, stderr } = await execFileAsync(binary, args, {
      cwd: AWR_REPO_ROOT,
      timeout: 15_000,
    });
    return { stdout, stderr, code: 0 };
  } catch (error: unknown) {
    const execError = error as { stdout?: string; stderr?: string; code?: number };
    return {
      stdout: execError.stdout ?? "",
      stderr: execError.stderr ?? "",
      code: execError.code ?? 1,
    };
  }
}

let awrBinary: string | undefined;
let binaryAvailable = false;

// Resolve binary once at module load time
const binaryReady = findAwrBinary().then((bin) => {
  awrBinary = bin;
  binaryAvailable = bin !== undefined;
});

describe("AWR integration", () => {

  test("awr <url> returns a valid visit envelope", async () => {
    if (!binaryAvailable) return;

    const result = await runAwr([MOCK_FIXTURE]);
    expect(result.code).toBe(0);

    const envelope = parseVisitEnvelope(result.stdout);
    expect(envelope).toBeDefined();
    expect(envelope!.url).toContain("webmcp_mock.html");
    expect(envelope!.status).toBe(200);
    expect(envelope!.title).toBe("WebMCP Mock Shop");
    expect(envelope!.body_text.length).toBeGreaterThan(0);
    expect(envelope!.tools.length).toBeGreaterThanOrEqual(3);
  });

  test("awr tools <url> returns WebMCP tool descriptors", async () => {
    if (!binaryAvailable) return;

    const result = await runAwr(["tools", MOCK_FIXTURE]);
    expect(result.code).toBe(0);

    const tools = parseToolsEnvelope(result.stdout);
    expect(tools).toBeDefined();
    expect(tools!.length).toBeGreaterThanOrEqual(3);

    const names = tools!.map((t) => t.name);
    expect(names).toContain("search_products");
    expect(names).toContain("get_price");
    expect(names).toContain("add_to_cart");

    const search = tools!.find((t) => t.name === "search_products");
    expect(search?.description).toBeTruthy();
    expect(search?.inputSchema).toBeDefined();
  });

  test("awr call <url> <tool> <json> invokes a sync page tool", async () => {
    if (!binaryAvailable) return;

    const result = await runAwr(["call", MOCK_FIXTURE, "search_products", '{"q":"Widget"}']);
    expect(result.code).toBe(0);

    const envelope = parseCallEnvelope(result.stdout);
    expect(envelope).toBeDefined();
    expect(envelope!.ok).toBe(true);

    const value = (envelope as { ok: true; value: unknown }).value as Array<{ name: string }>;
    expect(Array.isArray(value)).toBe(true);
    expect(value.length).toBeGreaterThanOrEqual(1);
    expect(value[0].name).toContain("Widget");
  });

  test("awr call <url> <tool> <json> invokes an async page tool", async () => {
    if (!binaryAvailable) return;

    const result = await runAwr(["call", MOCK_FIXTURE, "add_to_cart", '{"sku":"w-001","qty":2}']);
    expect(result.code).toBe(0);

    const envelope = parseCallEnvelope(result.stdout);
    expect(envelope).toBeDefined();
    expect(envelope!.ok).toBe(true);

    const value = (envelope as { ok: true; value: unknown }).value as { cart_size: number; total: number };
    expect(value.cart_size).toBeGreaterThanOrEqual(1);
    expect(value.total).toBeGreaterThan(0);
  });

  test("awr call returns error envelope for unknown tool", async () => {
    if (!binaryAvailable) return;

    const result = await runAwr(["call", MOCK_FIXTURE, "nope", "{}"]);
    expect(result.code).not.toBe(0);

    const envelope = parseCallEnvelope(result.stdout);
    expect(envelope).toBeDefined();
    expect(envelope!.ok).toBe(false);

    const errorEnvelope = envelope as { ok: false; error: string; message: string };
    expect(errorEnvelope.error).toBe("ToolNotFound");
    expect(errorEnvelope.message).toContain("nope");
  });

  test("awr call returns error envelope for bad JSON args", async () => {
    if (!binaryAvailable) return;

    const result = await runAwr(["call", MOCK_FIXTURE, "search_products", "not-json"]);
    expect(result.code).not.toBe(0);

    const envelope = parseCallEnvelope(result.stdout);
    expect(envelope).toBeDefined();
    expect(envelope!.ok).toBe(false);

    const errorEnvelope = envelope as { ok: false; error: string; message: string };
    expect(errorEnvelope.error).toBe("InvalidArgs");
  });

  test("awr get_price returns a specific product price", async () => {
    if (!binaryAvailable) return;

    const result = await runAwr(["call", MOCK_FIXTURE, "get_price", '{"sku":"w-002"}']);
    expect(result.code).toBe(0);

    const envelope = parseCallEnvelope(result.stdout);
    expect(envelope).toBeDefined();
    expect(envelope!.ok).toBe(true);

    const value = (envelope as { ok: true; value: unknown }).value as { sku: string; price: number };
    expect(value.sku).toBe("w-002");
    expect(value.price).toBe(14.99);
  });
});
