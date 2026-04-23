# Browser TUI — deferred sub-spec

> **Status:** DEFERRED
> Not part of the active work queue.
> Keep the main focus on the CLI browser runtime before investing here.

---

## Purpose

Preserve the intended browser/TUI direction without letting it compete with the
active runtime work.

---

## Scope for later

When this track is explicitly activated, it should cover:

- `browse` / `browser.zig` / `tui.zig` usability and stability;
- readable terminal navigation, scrolling, link following, and search;
- renderer polish that improves human browsing without regressing the CLI-first
  page execution path.

---

## Guardrail

This track is intentionally downstream of the shipped browser-runtime MVP path.
`awr <url>` stays the main product path until this deferred spec is promoted.
