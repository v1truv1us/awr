import { basename, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { StringEnum } from "@earendil-works/pi-ai";
import {
  getAgentDir,
  type ExecResult,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { type Static, Type } from "typebox";

import { buildCallArgs, buildToolsArgs, buildVisitArgs, parseCallEnvelope, parseToolsEnvelope, parseVisitEnvelope } from "./awr";
import { buildAwrWebConfig } from "./config";
import { loadFallbackHtml, htmlToFallbackPage, serializeCallArgs } from "./fallback";
import { formatCallContent, formatToolsContent, formatVisitContent } from "./format";
import { appendProblemRecord, createProblemId, formatProblemDetails, formatProblemSummary, readRecentProblemRecords } from "./logging";
import type { AwrWebConfig, ProblemKind, ProblemRecord, WebToolDetails } from "./types";

const PACKAGE_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const WEB_TOOL_PARAMETERS = Type.Object({
  action: StringEnum(["visit", "tools", "call"] as const),
  url: Type.String({ description: "URL, file:// URL, or local path to load with AWR" }),
  tool: Type.Optional(Type.String({ description: "Page tool name when action=call" })),
  args: Type.Optional(Type.Unknown({ description: "JSON-serializable args object when action=call" })),
});

interface AwrExecutionAttempt {
  binary: string;
  result: ExecResult;
}

type WebToolInput = Static<typeof WEB_TOOL_PARAMETERS>;

function getConfig(): AwrWebConfig {
  return buildAwrWebConfig({
    agentDir: getAgentDir(),
    packageDir: PACKAGE_DIR,
    env: process.env as Record<string, string | undefined>,
  });
}

function dedupe(values: string[]): string[] {
  return values.filter((value, index) => values.indexOf(value) === index);
}

function formatBinaryLabel(binary: string | undefined, config: AwrWebConfig): string {
  const resolved = binary ?? config.awrBinaryCandidates[0] ?? "awr";
  return resolved.includes("/") ? basename(resolved) : resolved;
}

function isLikelyMissingBinary(binary: string, result: ExecResult): boolean {
  if (result.code === 0 || result.killed) {
    return false;
  }

  if (result.stdout.trim().length > 0 || result.stderr.trim().length > 0) {
    return false;
  }

  return binary.includes("/") || binary === "awr";
}

function buildProblemRecord(
  kind: ProblemKind,
  summary: string,
  fields: Partial<ProblemRecord> = {},
): ProblemRecord {
  return {
    id: createProblemId(),
    timestamp: new Date().toISOString(),
    kind,
    summary,
    ...fields,
  };
}

function problemMessage(record: ProblemRecord, logPath: string): string {
  return `${record.summary} Logged as ${record.id} in ${logPath}.`;
}

function getProblemCount(args: string): number {
  const parsed = Number.parseInt(args.trim(), 10);
  if (Number.isNaN(parsed) || parsed < 1) {
    return 10;
  }
  return Math.min(parsed, 50);
}

async function runAwr(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  state: { lastSuccessfulBinary?: string },
  args: string[],
): Promise<AwrExecutionAttempt> {
  const config = getConfig();
  const candidates = dedupe([
    ...(state.lastSuccessfulBinary ? [state.lastSuccessfulBinary] : []),
    ...config.awrBinaryCandidates,
  ]);

  let lastAttempt: AwrExecutionAttempt | undefined;

  for (const binary of candidates) {
    const result = await pi.exec(binary, args, {
      cwd: ctx.cwd,
      signal: ctx.signal,
      timeout: 30_000,
    });
    const attempt = { binary, result };

    if (isLikelyMissingBinary(binary, result)) {
      lastAttempt = attempt;
      continue;
    }

    if (result.code === 0 || result.stdout.trim().length > 0) {
      state.lastSuccessfulBinary = binary;
    }

    return attempt;
  }

  return lastAttempt ?? {
    binary: config.awrBinaryCandidates[0] ?? "awr",
    result: { stdout: "", stderr: "", code: 1, killed: false },
  };
}

async function logProblem(record: ProblemRecord): Promise<ProblemRecord> {
  await appendProblemRecord(getConfig().problemLogPath, record);
  return record;
}

function visitDetails(
  url: string,
  backend: "awr" | "fallback",
  fields: Partial<WebToolDetails> = {},
): WebToolDetails {
  return {
    action: "visit",
    backend,
    url,
    ...fields,
  };
}

function buildStatusText(state: { lastSuccessfulBinary?: string }): string {
  const config = getConfig();
  return [
    `last successful binary: ${state.lastSuccessfulBinary ?? "(none yet)"}`,
    `candidate order: ${config.awrBinaryCandidates.join(", ")}`,
    `fallback mode: ${config.fallbackMode}`,
    `problem log: ${config.problemLogPath}`,
  ].join("\n");
}

async function handleVisit(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  state: { lastSuccessfulBinary?: string },
  input: WebToolInput,
): Promise<{ content: Array<{ type: "text"; text: string }>; details: WebToolDetails }> {
  const config = getConfig();
  const attempt = await runAwr(pi, ctx, state, buildVisitArgs(input.url));
  const parsed = attempt.result.stdout.trim().length > 0 ? parseVisitEnvelope(attempt.result.stdout) : undefined;

  if (parsed) {
    return {
      content: [{ type: "text", text: formatVisitContent(parsed, { backend: "awr" }) }],
      details: visitDetails(input.url, "awr", {
        awrBinary: attempt.binary,
        status: parsed.status,
        title: parsed.title ?? undefined,
        tools: parsed.tools,
      }),
    };
  }

  const failure = await logProblem(
    buildProblemRecord(
      attempt.result.stdout.trim().length > 0 ? "awr_invalid_json" : "awr_exec_failed",
      `AWR visit failed for ${input.url}`,
      {
        action: "visit",
        url: input.url,
        awrBinary: attempt.binary,
        exitCode: attempt.result.code,
        stdoutPreview: attempt.result.stdout,
        stderrPreview: attempt.result.stderr,
      },
    ),
  );

  if (config.fallbackMode === "none") {
    throw new Error(problemMessage(failure, config.problemLogPath));
  }

  try {
    const fallback = await loadFallbackHtml(input.url, ctx.cwd, ctx.signal);
    const page = htmlToFallbackPage(fallback.html);
    const content = formatVisitContent(
      {
        url: input.url,
        status: fallback.status,
        title: page.title,
        body_text: page.bodyText,
        window_data: null,
        tools: [],
      },
      {
        backend: "fallback",
        fallbackReason: failure.summary,
        problemId: failure.id,
        logPath: config.problemLogPath,
      },
    );

    await logProblem(
      buildProblemRecord("fallback_used", `Fallback visit used for ${input.url}`, {
        action: "visit",
        url: input.url,
        awrBinary: attempt.binary,
        note: failure.id,
      }),
    );

    return {
      content: [{ type: "text", text: content }],
      details: visitDetails(input.url, "fallback", {
        awrBinary: attempt.binary,
        status: fallback.status,
        title: page.title,
        tools: [],
        problemId: failure.id,
        problemLogPath: config.problemLogPath,
        fallbackReason: failure.summary,
      }),
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await logProblem(
      buildProblemRecord("fallback_failed", `Fallback visit failed for ${input.url}`, {
        action: "visit",
        url: input.url,
        note: message,
      }),
    );
    throw new Error(`${problemMessage(failure, config.problemLogPath)} Fallback also failed: ${message}`);
  }
}

async function handleTools(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  state: { lastSuccessfulBinary?: string },
  input: WebToolInput,
): Promise<{ content: Array<{ type: "text"; text: string }>; details: WebToolDetails }> {
  const config = getConfig();
  const attempt = await runAwr(pi, ctx, state, buildToolsArgs(input.url));
  const parsed = attempt.result.stdout.trim().length > 0 ? parseToolsEnvelope(attempt.result.stdout) : undefined;

  if (!parsed) {
    const failure = await logProblem(
      buildProblemRecord("awr_exec_failed", `AWR tools failed for ${input.url}`, {
        action: "tools",
        url: input.url,
        awrBinary: attempt.binary,
        exitCode: attempt.result.code,
        stdoutPreview: attempt.result.stdout,
        stderrPreview: attempt.result.stderr,
      }),
    );
    throw new Error(problemMessage(failure, config.problemLogPath));
  }

  return {
    content: [{ type: "text", text: formatToolsContent(input.url, parsed) }],
    details: {
      action: "tools",
      backend: "awr",
      url: input.url,
      awrBinary: attempt.binary,
      tools: parsed,
    },
  };
}

async function handleCall(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  state: { lastSuccessfulBinary?: string },
  input: WebToolInput,
): Promise<{ content: Array<{ type: "text"; text: string }>; details: WebToolDetails }> {
  if (!input.tool) {
    throw new Error("The web tool requires tool when action=call.");
  }

  const config = getConfig();
  const attempt = await runAwr(pi, ctx, state, buildCallArgs(input.url, input.tool, serializeCallArgs(input.args)));
  const parsed = attempt.result.stdout.trim().length > 0 ? parseCallEnvelope(attempt.result.stdout) : undefined;

  if (!parsed) {
    const failure = await logProblem(
      buildProblemRecord("awr_exec_failed", `AWR call failed for ${input.url}#${input.tool}`, {
        action: "call",
        url: input.url,
        toolName: input.tool,
        awrBinary: attempt.binary,
        exitCode: attempt.result.code,
        stdoutPreview: attempt.result.stdout,
        stderrPreview: attempt.result.stderr,
      }),
    );
    throw new Error(problemMessage(failure, config.problemLogPath));
  }

  if (!parsed.ok) {
    throw new Error(`Page tool ${input.tool} failed (${parsed.error}): ${parsed.message}`);
  }

  return {
    content: [{ type: "text", text: formatCallContent(input.url, input.tool, parsed.value) }],
    details: {
      action: "call",
      backend: "awr",
      url: input.url,
      awrBinary: attempt.binary,
      toolName: input.tool,
      value: parsed.value,
    },
  };
}

export default function awrWebExtension(pi: ExtensionAPI) {
  const state: { lastSuccessfulBinary?: string } = {};

  const updateStatus = (ctx: ExtensionContext) => {
    const config = getConfig();
    ctx.ui.setStatus(
      "awr-web",
      `web:${formatBinaryLabel(state.lastSuccessfulBinary, config)} fallback:${config.fallbackMode}`,
    );
  };

  pi.on("session_start", (_event, ctx) => {
    updateStatus(ctx);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    ctx.ui.setStatus("awr-web", undefined);
  });

  pi.registerTool({
    name: "web",
    label: "Web (AWR)",
    description:
      "Use AWR to visit pages, list WebMCP page tools, and call page tools. Falls back to a degraded HTML/text fetch for visit only when AWR fails.",
    promptSnippet:
      "Visit web pages with AWR, inspect page WebMCP tools, and invoke page tools from the same page.",
    promptGuidelines: [
      "Use web when the user needs webpage access, page tool discovery, or a page tool call instead of using bash with curl.",
      "Use web with action=visit to inspect a page, action=tools to list page tools, and action=call to invoke a page tool.",
    ],
    parameters: WEB_TOOL_PARAMETERS,
    async execute(_toolCallId, input, _signal, _onUpdate, ctx) {
      const result =
        input.action === "visit"
          ? await handleVisit(pi, ctx, state, input)
          : input.action === "tools"
            ? await handleTools(pi, ctx, state, input)
            : await handleCall(pi, ctx, state, input);

      updateStatus(ctx);
      return result;
    },
  });

  pi.registerCommand("awr-status", {
    description: "Show AWR web extension status",
    handler: async (_args, ctx) => {
      ctx.ui.notify(buildStatusText(state), "info");
    },
  });

  pi.registerCommand("awr-note", {
    description: "Log a manual AWR problem note: /awr-note <text>",
    handler: async (args, ctx) => {
      const note = args.trim() || (await ctx.ui.input("AWR note", "Describe the AWR issue..."))?.trim() || "";
      if (!note) {
        ctx.ui.notify("No note recorded", "warning");
        return;
      }

      const record = await logProblem(
        buildProblemRecord("manual_note", note, {
          action: "note",
          note,
        }),
      );
      ctx.ui.notify(`Recorded ${record.id}`, "info");
    },
  });

  pi.registerCommand("awr-problems", {
    description: "Browse recent AWR problems: /awr-problems [count]",
    handler: async (args, ctx) => {
      const config = getConfig();
      const records = await readRecentProblemRecords(config.problemLogPath, getProblemCount(args));
      if (records.length === 0) {
        ctx.ui.notify(`No AWR problems logged yet at ${config.problemLogPath}`, "info");
        return;
      }

      const choices = records
        .slice()
        .reverse()
        .map((record) => ({
          label: `${record.id} ${formatProblemSummary(record)}`,
          record,
        }));
      const selected = await ctx.ui.select(
        "Recent AWR problems",
        choices.map((choice) => choice.label),
      );
      const match = choices.find((choice) => choice.label === selected);
      if (!match) {
        return;
      }

      await ctx.ui.editor(`AWR problem ${match.record.id}`, formatProblemDetails(match.record));
    },
  });
}
