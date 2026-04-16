---
type: bug
priority: high
created: 2026-03-28
status: open
tags: [awr, phase1, h2, correctness]
labels: [awr, bug, phase1, agent]
keywords: [h2_shim.c, nghttp2_submit_request, pseudo-header, :authority, :scheme]
patterns: [nghttp2 headers array, nv[] struct]
---

# BUG-001: H2 pseudo-header order wrong in h2_shim.c

## Description

The H2 pseudo-header order in `src/net/h2_shim.c` does not match the Chrome 132 spec.

**Current:** `:method`, `:scheme`, `:authority`, `:path`
**Required:** `:method`, `:authority`, `:scheme`, `:path`

This is Phase 1 exit criterion item 8 and a confirmed correctness bug.

## Current State

`src/net/h2_shim.c` ~line 220 — the `nv[]` headers array passed to
`nghttp2_submit_request` has `:scheme` before `:authority`.

## Desired State

`:authority` appears before `:scheme` in the submitted headers.

## Fix

Swap the `:scheme` and `:authority` entries in the nv[] array.

## Success Criteria

### Automated Verification
- [ ] `zig build test-h2 --summary all` passes
- [ ] `zig build test --summary all` passes (no regression)

### Manual Verification
- [ ] Pseudo-header order confirmed as `:method :authority :scheme :path` in a frame capture
