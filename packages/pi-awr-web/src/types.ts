export type WebAction = "visit" | "tools" | "call";
export type FallbackMode = "visit" | "none";

export interface AwrWebConfig {
  awrBinaryCandidates: string[];
  fallbackMode: FallbackMode;
  problemLogPath: string;
}

export interface AwrToolDescriptor {
  name: string;
  description?: string;
  inputSchema?: unknown;
}

export interface AwrVisitEnvelope {
  url: string;
  status: number;
  title: string | null;
  body_text: string;
  window_data: unknown;
  tools: AwrToolDescriptor[];
}

export interface AwrCallSuccessEnvelope {
  ok: true;
  value: unknown;
}

export interface AwrCallErrorEnvelope {
  ok: false;
  error: string;
  message: string;
}

export type AwrCallEnvelope = AwrCallSuccessEnvelope | AwrCallErrorEnvelope;

export interface FallbackPage {
  title: string;
  bodyText: string;
}

export type ProblemKind =
  | "awr_unavailable"
  | "awr_exec_failed"
  | "awr_invalid_json"
  | "fallback_used"
  | "fallback_failed"
  | "manual_note";

export interface ProblemRecord {
  id: string;
  timestamp: string;
  kind: ProblemKind;
  summary: string;
  action?: WebAction | "note";
  url?: string;
  toolName?: string;
  awrBinary?: string;
  exitCode?: number;
  stdoutPreview?: string;
  stderrPreview?: string;
  note?: string;
}

export interface WebToolDetails {
  action: WebAction;
  backend: "awr" | "fallback";
  url: string;
  awrBinary?: string;
  toolName?: string;
  status?: number;
  title?: string;
  tools?: AwrToolDescriptor[];
  value?: unknown;
  problemId?: string;
  problemLogPath?: string;
  fallbackReason?: string;
}
