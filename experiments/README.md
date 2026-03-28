# AWR Experiments

Real-world fetch tests against sites of increasing JS/complexity. Run from repo root with `./zig-out/bin/awr <url>`.

## 2026-03-28 — Phase 2 baseline

| Site | URL | Result | Notes |
|------|-----|--------|-------|
| Hacker News | http://news.ycombinator.com | ❌ CRASH | Segfault — redirect URL buf overflow in client.zig:105 |
| GitHub | https://github.com | ✅ 200 | title correct, 140KB body_text, window_data=null |
| X / Twitter | https://x.com | ❌ ERROR | error.HttpHeadersOversize |

### Bug 1 — Redirect URL buffer overflow (HN crash)

Stack: `client.zig:105` → `std.fmt.bufPrint(&url_buf, "https://{s}:{d}{s}", ...)`

HN responds with HTTP 301 → https://news.ycombinator.com. The `url_buf` is too small
to hold the constructed HTTPS redirect URL. Segfault in `writeAll`.

**Fixed:** Heap-allocate the HTTPS redirect URL with `allocPrint` + `defer free`.
Also fixed a use-after-free in the HTTP redirect path — `loc` is a slice into
`resp.headers`, which is freed by `resp.deinit()` before the recursive `fetchUrl`
call. Fix: `allocator.dupe(loc)` before `resp.deinit()`, with `resp_owned` flag to
prevent double-free on the `errdefer` path. All 410/410 tests pass post-fix.

### Bug 2 — HttpHeadersOversize (X.com)

X returns a large number of HTTP response headers that exceed `std.http.Client`'s
internal header buffer. This is a `std.http.Client` limitation.

**Fixed:** Set `read_buffer_size = 64 * 1024` (64KB) on the `std.http.Client` instance
in `fetchHttpsViaStd`. Default was 8KB, which is too small for sites like X.com.
All 410/410 tests pass post-fix. Phase 3 (own TLS stack) will eliminate this entirely.

### GitHub notes

GitHub is partially server-rendered — the title and nav content are in the static HTML.
`body_text` is 140KB (full page text extracted by Lexbor). `window_data` is null because
GitHub doesn't set `window.__awrData__`. JS execution runs but no SPA data is surfaced.

This is the expected behaviour for a non-SPA site.
