import { describe, expect, test } from "bun:test";

import { buildAwrWebConfig } from "../src/config";

describe("buildAwrWebConfig", () => {
  test("prefers explicit binary env vars and de-duplicates candidates", () => {
    const config = buildAwrWebConfig({
      agentDir: "/tmp/pi-agent",
      packageDir: "/repo/awr/packages/pi-awr-web",
      env: {
        PI_AWR_BIN: "/custom/awr",
        AWR_BIN: "/custom/awr",
        PI_AWR_FALLBACK: "visit",
      },
    });

    expect(config.awrBinaryCandidates).toEqual([
      "/custom/awr",
      "/repo/awr/zig-out/bin/awr",
      "awr",
    ]);
    expect(config.fallbackMode).toBe("visit");
    expect(config.problemLogPath).toBe("/tmp/pi-agent/awr-web/problems.jsonl");
  });

  test("disables fallback when requested", () => {
    const config = buildAwrWebConfig({
      agentDir: "/tmp/pi-agent",
      packageDir: "/repo/awr/packages/pi-awr-web",
      env: {
        PI_AWR_FALLBACK: "none",
      },
    });

    expect(config.fallbackMode).toBe("none");
    expect(config.awrBinaryCandidates).toEqual([
      "/repo/awr/zig-out/bin/awr",
      "awr",
    ]);
  });
});
