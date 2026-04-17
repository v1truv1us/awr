# AWR Experiments

Real-world fetch tests. Run from repo root with `./zig-out/bin/awr <url>`.

## 2026-04-16 — Post-P0.1, post-Zig-0.16-migration

| Site | URL | Previous | Current | Notes |
|------|-----|----------|---------|-------|
| Hacker News | http://news.ycombinator.com | CRASH | Fixed | Redirect URL overflow fixed, link-list rendering added (P0.1) |
| GitHub | https://github.com | 200 | 200 | title correct, server-rendered, no SPA data |
| X / Twitter | https://x.com | ERROR | Fixed | HttpHeadersOversize fixed with 64KB read buffer |
| example.com | http://example.com | - | 200 | Known-good baseline |

### Changes since 2026-03-28 baseline

- **Zig 0.16 migration:** fixedBufferStream -> Io.Writer.fixed, trimRight -> trim, GPA -> c_allocator, ArrayListUnmanaged init -> .empty
- **P0.1 render fix:** Link-density heuristic (isLinkListTable) detects HN-style tables and renders as lists without column separators
- **Test suite:** 47/47 render tests passing
- **Known issue:** Vendored libxev uses @Type builtin removed in Zig 0.16 - prevents zig build of full binary but test-render works

### Previously fixed bugs (from 2026-03-28)

**Bug 1 - Redirect URL buffer overflow (HN crash):** Heap-allocate HTTPS redirect URL with allocPrint. Fix use-after-free in redirect path.

**Bug 2 - HttpHeadersOversize (X.com):** Set read_buffer_size = 64 * 1024 on std.http.Client. Default 8KB too small for X.com headers.

### Rerun instructions

```bash
for SITE in "http://example.com" "http://news.ycombinator.com" "https://github.com" "https://x.com"; do
  SLUG=$(echo "$SITE" | tr '/' '-' | tr ':' '-')
  ./zig-out/bin/awr "$SITE" 2> "experiments/${SLUG}-stderr.txt" 1> "experiments/${SLUG}-stdout.txt"
done
```

Note: Requires zig build to produce binary. Currently blocked on libxev Zig 0.16 compat.
