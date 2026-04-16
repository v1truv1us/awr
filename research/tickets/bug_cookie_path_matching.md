---
type: bug
priority: medium
created: 2026-03-28
status: open
tags: [awr, phase1, cookies, correctness, rfc6265]
labels: [awr, bug, phase1, agent]
keywords: [cookie.zig, path matching, startsWith, RFC 6265, SameSite]
patterns: [cookie send logic, path comparison]
---

# BUG-003: Cookie path matching too permissive — violates RFC 6265

## Description

`src/net/cookie.zig` ~line 138 uses `startsWith(request_path, cookie_path)`
for path matching. This incorrectly matches `/api` cookies against `/apiOld`
requests. RFC 6265 §5.1.4 requires that a path match only if the cookie path
is a prefix of the request path AND either:
- the paths are equal, or
- the next character after the cookie path in the request path is `/`

Additionally, `SameSite` is parsed but not enforced when sending cookies.

Phase 1 exit criterion item 12.

## Current State

- `src/net/cookie.zig` ~line 138: `startsWith` used directly
- SameSite parsed but not checked at send time

## Desired State

- RFC 6265 §5.1.4 path-match semantics implemented
- `/api` cookie does NOT match `/apiOld` request
- SameSite enforcement implemented or explicitly scoped out with a comment

## Fix

Replace raw `startsWith` with an RFC 6265 path-match function:
```
fn rfcPathMatch(request_path: []const u8, cookie_path: []const u8) bool {
    if (std.mem.eql(u8, request_path, cookie_path)) return true;
    if (!std.mem.startsWith(u8, request_path, cookie_path)) return false;
    if (cookie_path[cookie_path.len - 1] == '/') return true;
    return request_path[cookie_path.len] == '/';
}
```

## Success Criteria

### Automated Verification
- [ ] `zig build test-net --summary all` passes
- [ ] `zig build test --summary all` passes (no regression)
- [ ] Test: `/api` cookie does NOT match `/apiOld`
- [ ] Test: `/api` cookie DOES match `/api/users`
- [ ] Test: `/api/` cookie DOES match `/api/users`

### Manual Verification
- [ ] Path matching behavior verified against RFC 6265 §5.1.4 examples
