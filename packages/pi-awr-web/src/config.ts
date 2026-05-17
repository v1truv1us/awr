import { join, resolve } from "node:path";

import type { AwrWebConfig, FallbackMode } from "./types";

interface BuildAwrWebConfigOptions {
  agentDir: string;
  packageDir: string;
  env: Record<string, string | undefined>;
}

function normalizeFallbackMode(value: string | undefined): FallbackMode {
  return value === "none" ? "none" : "visit";
}

function unique(values: string[]): string[] {
  return values.filter((value, index) => value.length > 0 && values.indexOf(value) === index);
}

export function buildAwrBinaryCandidates(
  packageDir: string,
  env: Record<string, string | undefined>,
): string[] {
  return unique([
    env.PI_AWR_BIN ?? "",
    env.AWR_BIN ?? "",
    resolve(packageDir, "../../zig-out/bin/awr"),
    "awr",
  ]);
}

export function buildAwrWebConfig(options: BuildAwrWebConfigOptions): AwrWebConfig {
  return {
    awrBinaryCandidates: buildAwrBinaryCandidates(options.packageDir, options.env),
    fallbackMode: normalizeFallbackMode(options.env.PI_AWR_FALLBACK),
    problemLogPath: join(options.agentDir, "awr-web", "problems.jsonl"),
  };
}
