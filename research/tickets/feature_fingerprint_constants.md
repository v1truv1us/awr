---
type: feature
priority: high
created: 2026-03-28
status: open
tags: [awr, phase3, fingerprint, ja4]
labels: [awr, enhancement, phase3, agent]
keywords: [fingerprint.zig, awr_ciphers, awr_ja4, pickGrease, chrome132_ja4]
patterns: [fingerprint constants, GREASE selection, JA4 format]
---

# FEATURE-004: Phase 3 Step 3 — AWR fingerprint constants + pickGrease

## Description

Add AWR-specific fingerprint constants to `src/net/fingerprint.zig` and implement
`pickGrease` for per-session GREASE value selection.

This is Phase 3 Step 3 per `spec/Phase3-Plan.md`.

## Requirements

### Functional Requirements

- Add `awr_ciphers`: 15-entry cipher list (Chrome 132 minus 3DES `0x000A`)
- Add `awr_ja4`: placeholder string `"t13d????h2_????????????_????????????"` — real value computed at Step 5 when live TLS runs
- Add `awr_ja4h`: placeholder for HTTP header fingerprint
- Add `chrome132_ja4 = "t13d1517h2_8daaf6152771_b6f405a00624"` — for non-impersonation assertion
- Implement `pickGrease(seed: u64) u16` — picks from `grease_values` using `seed % 16`
- Add `spec/FINGERPRINT.md` documenting AWR's fingerprint policy

### Non-Functional Requirements

- All new constants must have tests
- `awr_ja4` must NOT equal `chrome132_ja4` (test this explicitly)
- `awr_ciphers` must not contain `0x000A`

## Current State

`src/net/fingerprint.zig` has Chrome 132 constants and GREASE values.
No AWR-specific cipher list or JA4 placeholder exists yet.

## Desired State

`fingerprint.zig` contains both Chrome 132 and AWR constants.
`pickGrease` is implemented and tested.
`spec/FINGERPRINT.md` documents AWR's fingerprint.

## Success Criteria

### Automated Verification
- [ ] `awr_ciphers` has exactly 15 entries
- [ ] `awr_ciphers` does not contain `0x000A`
- [ ] `awr_ciphers` contains `0x1301`, `0x1302`, `0x1303` (TLS 1.3 mandatory)
- [ ] `awr_ja4` does not equal `chrome132_ja4`
- [ ] `pickGrease(n)` always returns a value in `grease_values`
- [ ] `zig build test-net --summary all` passes (~8 new tests)

### Manual Verification
- [ ] `spec/FINGERPRINT.md` exists and documents the full fingerprint policy
