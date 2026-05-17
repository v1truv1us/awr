import type { AwrToolDescriptor, AwrVisitEnvelope } from "./types";
import { cleanBodyText, contentRatio } from "./clean";

const MAX_OUTPUT_CHARS = 48_000;

function truncateText(value: string): string {
  if (value.length <= MAX_OUTPUT_CHARS) {
    return value;
  }
  return `${value.slice(0, MAX_OUTPUT_CHARS)}\n\n[Output truncated at ${MAX_OUTPUT_CHARS} characters]`;
}

function formatToolList(tools: AwrToolDescriptor[]): string {
  if (tools.length === 0) {
    return "none";
  }

  return tools
    .map((tool) => {
      const parts = [tool.name];
      if (tool.description) {
        parts.push(`— ${tool.description}`);
      }
      if (tool.inputSchema && typeof tool.inputSchema === "object" && tool.inputSchema !== null) {
        const schema = tool.inputSchema as Record<string, unknown>;
        const props = schema.properties as Record<string, unknown> | undefined;
        if (props) {
          const paramList = Object.keys(props).join(", ");
          parts.push(`params: ${paramList}`);
        }
        const required = schema.required as string[] | undefined;
        if (required && required.length > 0) {
          parts.push(`required: ${required.join(", ")}`);
        }
      }
      return parts.join(" ");
    })
    .join("\n");
}

export function formatVisitContent(
  envelope: AwrVisitEnvelope,
  options: {
    backend: "awr" | "fallback";
    fallbackReason?: string;
    problemId?: string;
    logPath?: string;
  },
): string {
  const rawBody = envelope.body_text.trim();
  const cleanedBody = cleanBodyText(rawBody);
  const ratio = contentRatio(rawBody);

  const lines: string[] = [];

  // Compact header block
  lines.push(`# ${envelope.title ?? "(untitled)"}`);
  lines.push(`${envelope.status} ${envelope.url} (${options.backend})`);

  if (options.fallbackReason) {
    lines.push(`fallback: ${options.fallbackReason}`);
  }
  if (options.problemId) {
    lines.push(`problem: ${options.problemId}`);
  }

  // Tools section
  if (envelope.tools.length > 0) {
    lines.push("");
    lines.push("## Page tools");
    lines.push(formatToolList(envelope.tools));
  }

  // Content quality hint when we stripped a lot
  if (rawBody.length > 200 && ratio < 0.5) {
    lines.push("");
    lines.push(`(content ratio: ${Math.round(ratio * 100)}% — high chrome, may be missing content)`);
  }

  // Body content
  lines.push("");
  lines.push("## Content");
  lines.push(cleanedBody || "(empty)");

  return truncateText(lines.join("\n"));
}

export function formatToolsContent(url: string, tools: AwrToolDescriptor[]): string {
  const lines = [`# Page tools for ${url}`, ""];
  lines.push(formatToolList(tools));
  return truncateText(lines.join("\n"));
}

export function formatCallContent(url: string, toolName: string, value: unknown): string {
  const lines = [
    `# ${toolName}`,
    `page: ${url}`,
    "",
    "## Result",
  ];

  if (typeof value === "string") {
    lines.push(value);
  } else {
    lines.push("```json");
    lines.push(JSON.stringify(value, null, 2));
    lines.push("```");
  }

  return truncateText(lines.join("\n"));
}
