import { appendFile, mkdir, readFile } from "node:fs/promises";
import { dirname } from "node:path";

import type { ProblemRecord } from "./types";

function preview(value: string | undefined, maxLength = 800): string | undefined {
  if (!value) {
    return undefined;
  }
  return value.length > maxLength ? `${value.slice(0, maxLength)}…` : value;
}

export function createProblemId(date = new Date()): string {
  const stamp = date.toISOString().replace(/[-:.TZ]/g, "").slice(0, 14);
  const random = Math.random().toString(36).slice(2, 8);
  return `awr-${stamp}-${random}`;
}

export async function appendProblemRecord(logPath: string, record: ProblemRecord): Promise<void> {
  await mkdir(dirname(logPath), { recursive: true });
  await appendFile(logPath, `${JSON.stringify(record)}\n`, "utf8");
}

export async function readRecentProblemRecords(
  logPath: string,
  limit: number,
): Promise<ProblemRecord[]> {
  try {
    const raw = await readFile(logPath, "utf8");
    const records = raw
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.length > 0)
      .map((line) => JSON.parse(line) as ProblemRecord);

    return records.slice(-limit);
  } catch {
    return [];
  }
}

export function formatProblemSummary(record: ProblemRecord): string {
  return `[${record.timestamp}] ${record.kind} - ${record.summary}`;
}

export function formatProblemDetails(record: ProblemRecord): string {
  const lines = [
    `id: ${record.id}`,
    `timestamp: ${record.timestamp}`,
    `kind: ${record.kind}`,
    `summary: ${record.summary}`,
  ];

  if (record.action) lines.push(`action: ${record.action}`);
  if (record.url) lines.push(`url: ${record.url}`);
  if (record.toolName) lines.push(`tool: ${record.toolName}`);
  if (record.awrBinary) lines.push(`awrBinary: ${record.awrBinary}`);
  if (record.exitCode !== undefined) lines.push(`exitCode: ${record.exitCode}`);
  if (record.note) lines.push(`note: ${record.note}`);
  if (record.stdoutPreview) lines.push(`stdout:\n${preview(record.stdoutPreview)}`);
  if (record.stderrPreview) lines.push(`stderr:\n${preview(record.stderrPreview)}`);

  return lines.join("\n\n");
}
