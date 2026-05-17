import type { AwrCallEnvelope, AwrToolDescriptor, AwrVisitEnvelope } from "./types";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function parseJson(text: string): unknown {
  return JSON.parse(text.trim());
}

export function buildVisitArgs(url: string): string[] {
  return [url];
}

export function buildToolsArgs(url: string): string[] {
  return ["tools", url];
}

export function buildCallArgs(url: string, toolName: string, argsJson: string): string[] {
  return ["call", url, toolName, argsJson];
}

export function parseVisitEnvelope(stdout: string): AwrVisitEnvelope | undefined {
  const parsed = parseJson(stdout);
  if (!isRecord(parsed)) return undefined;
  if (typeof parsed.url !== "string") return undefined;
  if (typeof parsed.status !== "number") return undefined;
  if (typeof parsed.body_text !== "string") return undefined;
  if (!Array.isArray(parsed.tools)) return undefined;

  return {
    url: parsed.url,
    status: parsed.status,
    title: typeof parsed.title === "string" ? parsed.title : null,
    body_text: parsed.body_text,
    window_data: parsed.window_data,
    tools: parsed.tools.filter(isToolDescriptor),
  };
}

function isToolDescriptor(value: unknown): value is AwrToolDescriptor {
  if (!isRecord(value)) return false;
  return typeof value.name === "string";
}

export function parseToolsEnvelope(stdout: string): AwrToolDescriptor[] | undefined {
  const parsed = parseJson(stdout);
  if (!Array.isArray(parsed)) return undefined;
  return parsed.filter(isToolDescriptor);
}

export function parseCallEnvelope(stdout: string): AwrCallEnvelope | undefined {
  const parsed = parseJson(stdout);
  if (!isRecord(parsed) || typeof parsed.ok !== "boolean") return undefined;

  if (parsed.ok) {
    return { ok: true, value: parsed.value };
  }

  if (typeof parsed.error !== "string" || typeof parsed.message !== "string") {
    return undefined;
  }

  return {
    ok: false,
    error: parsed.error,
    message: parsed.message,
  };
}
