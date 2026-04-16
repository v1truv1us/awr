---
type: bug
priority: high
created: 2026-03-28
status: open
tags: [awr, phase1, https, redirects, correctness]
labels: [awr, bug, phase1, agent]
keywords: [client.zig, redirect_count, fetchHttpsCurl, HTTPS redirect]
patterns: [redirect recursion, max_redirects]
---

# BUG-002: HTTPS redirect counter resets to 0 on each hop

## Description

The HTTPS redirect path in `src/client.zig` resets `redirect_count` to `0`
instead of passing `redirect_count + 1`. This means a redirect chain of any
length will never hit the 10-hop limit, and infinite redirect loops are possible.

Phase 1 exit criterion item 13.

## Current State

`src/client.zig` ~line 347: recursive call passes `redirect_count: 0`.
HTTP path at ~line 211 correctly passes `redirect_count + 1`.

## Desired State

HTTPS recursive call passes `redirect_count + 1`, matching the HTTP path.

## Fix

Change the recursive HTTPS fetch call to pass `redirect_count: redirect_count + 1`.

## Success Criteria

### Automated Verification
- [ ] `zig build test-client --summary all` passes
- [ ] `zig build test --summary all` passes (no regression)
- [ ] Test: 3-hop HTTPS redirect chain follows correctly
- [ ] Test: Chain > 10 hops returns error

### Manual Verification
- [ ] Redirect counter increments correctly on HTTPS path
