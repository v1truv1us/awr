# MVP remainder — closure record

> **Status:** COMPLETE
> The browser-runtime MVP path described here is shipped on the primary CLI
> surface.
> `spec/MVP.md` is the canonical umbrella spec.

---

## Goal

This file records how the browser-runtime remainder on the primary CLI path was
closed after the initial WebMCP slice shipped.

This track is about making `awr <url>` and its supporting runtime behave like a
real, usable browser core for agent workflows.

---

## Shipped scope

### 1. Real page fetch on the main path

- `awr <https-url>` and `awr <http-url>` must fetch real pages.
- `file://` and bare-path loading remain supported.
- Redirects and stderr diagnostics must behave predictably.

### 2. Script and async runtime closure

- External `<script src="…">` loading works.
- `setTimeout` / `setInterval` actually fire.
- Page `fetch()` uses the Zig HTTP client.
- `structuredClone` exists for JSON-compatible values.
- Promise/microtask + timer/macrotask draining is sufficient before result
  extraction.

### 3. DOM fidelity needed by page code

- JS DOM mutations are reflected back to the Zig-visible DOM state.
- Selector support expands to the documented remainder needed by current tests
  and fixtures (`[attr]`, `[attr=value]`, `:not`, `>`, `+`, `~`, multi-class).

### 4. Verification and doc sync on the browser path

- Acceptance/readiness docs reflect the new canonical spec layout.
- Browser-path checks focus on the real fetch → parse → execute flow, not on
  deferred protocol surfaces.

---

## Explicitly not in scope for this shipped track

- finishing native MCP stdio server mode
- browser/TUI feature work
- later fingerprinting and browser-identity work

Those remain documented, but deferred.

---

## Closure signals

This track is considered complete when the repo can truthfully claim all of the
following:

1. the primary `awr <url>` path works for disk and real network fetches;
2. external scripts and the core async JS hooks needed by fixtures/tests work;
3. DOM mutation read-back and selector coverage no longer block current browser
   scenarios;
4. docs consistently point readers to `spec/MVP.md` as canonical and keep the
   active-vs-deferred boundary obvious.

## Verification used for closure

- `zig build test-js`
- `zig build test-dom`
- `zig build test-page`
- `zig build test-client`
- `./scripts/mvp_smoke.sh`

These commands verify the shipped CLI/browser MVP path. They do not imply that
deferred TLS/TCP or other future-track targets are complete.
