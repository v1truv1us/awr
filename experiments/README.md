# AWR Experiments

Real-world fetch tests against sites of increasing JS/complexity. Run from repo root with `./zig-out/bin/awr <url>`.

## Local MVP fixtures

- `webmcp_mock.html`: base WebMCP tools fixture used by `awr tools`/`awr call`.
- `external_script.html`: exercises external `<script src>` loading.
- `async_tool.html`: exercises `setTimeout` + `fetch()` in a Promise-returning tool.
- `dom_mutation_tool.html`: exercises AT-8 style DOM mutation visibility (`appendChild` then immediate `querySelector`).

Suggested quick checks:

```bash
./zig-out/bin/awr tools experiments/webmcp_mock.html
./zig-out/bin/awr call experiments/async_tool.html fetch_then_wait '{}'
./zig-out/bin/awr call experiments/dom_mutation_tool.html mutate_and_query '{}'
```

## 2026-04-24 — Fetch matrix

| Site | URL | Result | Notes |
|------|-----|--------|-------|
| Example.com | https://example.com | ✅ 200 | title `Example Domain`, small static body |
| Hacker News | http://news.ycombinator.com | ✅ 200 | follows HTTPS redirect, title `Hacker News`, about 3.9K chars body text |
| GitHub | https://github.com | ✅ 200 | title correct, about 140K chars body text |
| X / Twitter | https://x.com | ✅ 200 | large response headers accepted, about 225K chars body text |

Notes:

- Hacker News exercises HTTP-to-HTTPS redirects plus a TLS 1.2 / ECDSA server path.
- X.com exercises large response headers beyond Zig std's default 8KB client buffer.
