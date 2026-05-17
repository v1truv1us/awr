import { fileURLToPath } from "node:url";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import type { FallbackPage } from "./types";

const BLOCK_TAG_PATTERN = /<(?:\/)?(?:p|div|section|article|header|footer|main|nav|li|ul|ol|h[1-6]|tr|table|br)[^>]*>/gi;
const TAG_PATTERN = /<[^>]+>/g;
const SCRIPT_PATTERN = /<script[\s\S]*?<\/script>/gi;
const STYLE_PATTERN = /<style[\s\S]*?<\/style>/gi;
const WHITESPACE_PATTERN = /\s+/g;

function decodeHtmlEntities(value: string): string {
  return value.replace(/&(#x?[0-9a-f]+|[a-z]+);/gi, (match, entity: string) => {
    const normalized = entity.toLowerCase();
    if (normalized === "amp") return "&";
    if (normalized === "lt") return "<";
    if (normalized === "gt") return ">";
    if (normalized === "quot") return '"';
    if (normalized === "apos") return "'";
    if (normalized === "nbsp") return " ";

    if (normalized.startsWith("#x")) {
      const codePoint = Number.parseInt(normalized.slice(2), 16);
      return Number.isNaN(codePoint) ? match : String.fromCodePoint(codePoint);
    }

    if (normalized.startsWith("#")) {
      const codePoint = Number.parseInt(normalized.slice(1), 10);
      return Number.isNaN(codePoint) ? match : String.fromCodePoint(codePoint);
    }

    return match;
  });
}

function collapseWhitespace(value: string): string {
  return value.replace(WHITESPACE_PATTERN, " ").trim();
}

function extractTitle(html: string): string {
  const match = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  return collapseWhitespace(decodeHtmlEntities(match?.[1] ?? ""));
}

function extractBodySource(html: string): string {
  const sanitized = html.replace(SCRIPT_PATTERN, " ").replace(STYLE_PATTERN, " ");
  const match = sanitized.match(/<body[^>]*>([\s\S]*?)<\/body>/i);
  return match?.[1] ?? sanitized;
}

function extractBodyText(html: string): string {
  const bodySource = extractBodySource(html);
  const withBlocks = bodySource.replace(BLOCK_TAG_PATTERN, "\n");
  const withoutTags = withBlocks.replace(TAG_PATTERN, " ");
  return collapseWhitespace(decodeHtmlEntities(withoutTags));
}

export function htmlToFallbackPage(html: string): FallbackPage {
  return {
    title: extractTitle(html),
    bodyText: extractBodyText(html),
  };
}

export function serializeCallArgs(args: unknown): string {
  const serialized = JSON.stringify(args ?? {});
  if (serialized === undefined) {
    throw new Error("Web tool call args must be JSON-serializable.");
  }
  return serialized;
}

function isHttpUrl(target: string): boolean {
  return /^https?:\/\//i.test(target);
}

function isFileUrl(target: string): boolean {
  return /^file:\/\//i.test(target);
}

export async function loadFallbackHtml(
  target: string,
  cwd: string,
  signal?: AbortSignal,
): Promise<{ source: string; status: number; html: string }> {
  if (isHttpUrl(target)) {
    const response = await fetch(target, { signal });
    return {
      source: target,
      status: response.status,
      html: await response.text(),
    };
  }

  const filePath = isFileUrl(target) ? fileURLToPath(target) : resolve(cwd, target);
  return {
    source: filePath,
    status: 200,
    html: await readFile(filePath, "utf8"),
  };
}
