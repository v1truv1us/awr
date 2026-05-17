# pi-awr-web

Pi package that provides a `web` tool backed by AWR.

## What it does

- Uses **AWR** as the primary web/page backend
- Exposes a pi-native `web` tool with three actions:
  - `visit`
  - `tools`
  - `call`
- Falls back to a degraded HTML/text fetch for `visit` when AWR fails
- Logs AWR backend problems so you can track breakage while AWR evolves

## Install

Local install:

```bash
pi install /Users/johnferguson/Github/awr/packages/pi-awr-web
```

If AWR is not already on your `PATH`, point the extension at a binary:

```bash
export PI_AWR_BIN=/Users/johnferguson/Github/awr/zig-out/bin/awr
```

## Tool usage

The extension registers a `web` tool.

### Visit a page

- `action: "visit"`
- returns status, title, body text, and discovered page tools

### List page tools

- `action: "tools"`
- returns page-registered WebMCP tools and their schemas

### Call a page tool

- `action: "call"`
- requires `tool`
- optional `args` must be JSON-serializable

## Commands

- `/awr-status` — show binary selection, fallback mode, and log path
- `/awr-problems [count]` — browse recent logged problems
- `/awr-note <text>` — manually log a note about an AWR issue

## Fallback behavior

Fallback currently applies to `visit` only.

When AWR fails for a visit, the extension:

1. logs the AWR failure
2. attempts a degraded fetch/read path
3. returns stripped text content with a note that fallback was used

`tools` and `call` do **not** fall back to a secondary browser backend yet.

## Problem logs

By default, problems are stored at:

```text
~/.pi/agent/awr-web/problems.jsonl
```

Each record includes an id, timestamp, problem kind, summary, and stdout/stderr previews when available.

## Configuration

Environment variables:

- `PI_AWR_BIN` — preferred AWR binary path
- `AWR_BIN` — secondary AWR binary override
- `PI_AWR_FALLBACK=none` — disable degraded visit fallback

## Development

```bash
bun install
bun test
bun run typecheck
bun run lint
```
