import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { appendProblemRecord, readRecentProblemRecords } from "../src/logging";

describe("problem logging", () => {
  test("appends and reads back recent problem records", async () => {
    const tempDir = await mkdtemp(join(tmpdir(), "pi-awr-web-"));
    const logPath = join(tempDir, "problems.jsonl");

    try {
      await appendProblemRecord(logPath, {
        id: "p1",
        timestamp: "2026-05-07T00:00:00.000Z",
        kind: "awr_exec_failed",
        summary: "AWR exited non-zero",
      });
      await appendProblemRecord(logPath, {
        id: "p2",
        timestamp: "2026-05-07T00:01:00.000Z",
        kind: "fallback_used",
        summary: "Used degraded HTML fallback",
      });

      const file = await readFile(logPath, "utf8");
      expect(file.trim().split("\n")).toHaveLength(2);

      const recent = await readRecentProblemRecords(logPath, 1);
      expect(recent).toEqual([
        {
          id: "p2",
          timestamp: "2026-05-07T00:01:00.000Z",
          kind: "fallback_used",
          summary: "Used degraded HTML fallback",
        },
      ]);
    } finally {
      await rm(tempDir, { recursive: true, force: true });
    }
  });
});
