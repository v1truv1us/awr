# WPT Conformance Doc Hygiene — Implementation Plan

> **Phase:** plan
> **Spec:** `specs/wpt-conformance-doc-hygiene/spec.md`
> **Status:** ready to execute — all four gating signals in spec §7 are satisfied
> (agent-browser closed 2026-04-28, rendering closed 2026-04-30, §8 reconciled
> in commit `4336250` on 2026-05-01)
> **Created:** 2026-05-02

---

## Context

`specs/wpt-conformance-doc-hygiene/spec.md` defines a contract that keeps
`spec/subspecs/wpt-conformance.md §8` in sync with the `curated_cases` arrays
in both conformance runners. The spec deferred mechanical enforcement until MVP
closure (§5.1). That closure gate has now fired — all browser sub-specs are
closed and §8 has been reconciled. This plan implements the §5.3 mechanical
enforcement.

The deliverable is a single Zig test file (`tests/wpt_doc_check.zig`) wired
under `zig build test` that fails CI whenever §8 drifts from the runners.

---

## Approach

**Hand-rolled scanner using `@embedFile`** (spec §8 open question #3 answer:
not a separate machine-readable file, not regex-over-runtime-reads — compile-time
embed of three existing files).

The doc-check module embeds three files at compile time:
- `spec/subspecs/wpt-conformance.md` — the doc to validate
- `tests/wpt_runner.zig` — authoritative source for active WPT filename list
- `tests/test262_runner.zig` — authoritative source for Test262 case count

All parsing is pure `[]const u8` slice operations on those embedded bytes.
The module has **no imports except `std`** — no C libs, no QuickJS, no page
pipeline. It compiles in seconds and runs offline.

---

## Tasks

### Phase 1 — Core scanner (`tests/wpt_doc_check.zig`)

#### DOCCHECK-001: WPT filename extractor for spec §8a/§8b

| Field | Value |
|---|---|
| **ID** | DOCCHECK-001 |
| **Title** | Implement §8a / §8b filename scanners |
| **Depends On** | None |
| **Files** | `tests/wpt_doc_check.zig` (create) |
| **Estimated Time** | 45 min |
| **Complexity** | Medium |

**Spec reference:** `specs/wpt-conformance-doc-hygiene/spec.md §5.3` bullets 1–2, §2.1, §2.2

**Acceptance criteria:**
- [ ] `extractSection8aFilenames` returns a slice of all backticked `*.js` tokens
      found between the `### §8a` heading and the `### §8b` heading in the
      embedded markdown.
- [ ] `extractSection8bFilenames` returns a slice of all backticked `*.js` tokens
      found from the `### §8b` heading to end-of-file.
- [ ] Both functions ignore the `JS runtime` row (which contains no `*.js` token).
- [ ] Both functions handle multi-token rows correctly (one `|`-row may contain
      several backtick-filenames; all are extracted).
- [ ] Both functions allocate into a provided `std.ArrayList([]const u8)` and
      return an owned slice; caller frees.

**Implementation notes:**
- Section boundary detection: scan for `\n### §8a` and `\n### §8b` byte sequences.
- Token extraction: scan the section bytes for `` ` `` open, collect until next
  `` ` ``, include only if token ends with `.js`.
- The `testharness_shim.js` harness file must NOT appear in §8 at all — it is
  excluded from `curated_cases` by convention. The scanners don't need to
  special-case it; if it appears in §8 it would trigger the disjoint check.

---

#### DOCCHECK-002: curated_cases filename extractor from `tests/wpt_runner.zig`

| Field | Value |
|---|---|
| **ID** | DOCCHECK-002 |
| **Title** | Extract curated WPT filenames from embedded runner source |
| **Depends On** | None |
| **Files** | `tests/wpt_doc_check.zig` |
| **Estimated Time** | 20 min |
| **Complexity** | Low |

**Spec reference:** `specs/wpt-conformance-doc-hygiene/spec.md §5.3` bullet 1

**Acceptance criteria:**
- [ ] `extractWptRunnerFilenames` scans the embedded `tests/wpt_runner.zig` bytes
      for every occurrence of `.filename = "`, extracts the quoted value, and
      returns an owned slice.
- [ ] Order is preserved (insertion order in the source).
- [ ] The extracted count matches `curated_cases.len` as verified by a separate
      count assertion in the test body.

**Implementation notes:**
- Pattern: `.filename = "` followed by bytes until the closing `"`.
- The format is machine-written Zig struct literals; the pattern is stable.

---

#### DOCCHECK-003: Test262 case count extractor from `tests/test262_runner.zig`

| Field | Value |
|---|---|
| **ID** | DOCCHECK-003 |
| **Title** | Count curated Test262 cases from embedded runner source |
| **Depends On** | None |
| **Files** | `tests/wpt_doc_check.zig` |
| **Estimated Time** | 15 min |
| **Complexity** | Low |

**Spec reference:** `specs/wpt-conformance-doc-hygiene/spec.md §5.3` bullet 6

**Acceptance criteria:**
- [ ] `countTest262Cases` scans the embedded `tests/test262_runner.zig` bytes and
      counts occurrences of `.name = "`.
- [ ] Count equals the actual `curated_cases.len` (verified manually at plan time:
      46 as of `4336250`).

---

#### DOCCHECK-004: Header-note count parser

| Field | Value |
|---|---|
| **ID** | DOCCHECK-004 |
| **Title** | Parse WPT / Test262 counts from §8 header note |
| **Depends On** | None |
| **Files** | `tests/wpt_doc_check.zig` |
| **Estimated Time** | 20 min |
| **Complexity** | Low |

**Spec reference:** `specs/wpt-conformance-doc-hygiene/spec.md §5.3` bullets 5–6, §2.3

**Acceptance criteria:**
- [ ] `parseHeaderNoteCounts` finds the `Current status` block in the embedded
      markdown and extracts the two integer counts: `N active curated WPT cases`
      and `M Test262 cases`.
- [ ] Returns a struct `{ wpt: usize, test262: usize }` or an error if the
      pattern is not found (malformed header → test fails with a clear message).

**Implementation notes:**
- Pattern: scan for `active curated WPT cases`; the integer immediately precedes
  it after optional whitespace. Scan for `Test262 cases`; same rule.
- `std.fmt.parseInt` for integer extraction.

---

#### DOCCHECK-005: Assertions and test body

| Field | Value |
|---|---|
| **ID** | DOCCHECK-005 |
| **Title** | Wire all four extractors into a single `test` block with clear failure messages |
| **Depends On** | DOCCHECK-001, DOCCHECK-002, DOCCHECK-003, DOCCHECK-004 |
| **Files** | `tests/wpt_doc_check.zig` |
| **Estimated Time** | 30 min |
| **Complexity** | Medium |

**Spec reference:** `specs/wpt-conformance-doc-hygiene/spec.md §5.3` bullets 1–6

**Acceptance criteria:**
- [ ] Test name: `"§8 ↔ curated_cases alignment"`.
- [ ] Assertion A: `§8a` active set equals `curated_cases` filenames (order-
      insensitive set comparison; both sorted before `std.testing.expectEqual`).
      Failure message names any filename present in one set but not the other.
- [ ] Assertion B: `§8b` deferred set is disjoint from §8a active set. Failure
      names the duplicate filename.
- [ ] Assertion C: header-note WPT count equals `curated_cases.len` (from
      DOCCHECK-002).
- [ ] Assertion D: header-note Test262 count equals count from DOCCHECK-003.
- [ ] Assertion E: every deferred filename in §8b either has `(not yet written)`
      anywhere on its row OR `std.fs.cwd().access("tests/wpt/" ++ filename)`
      succeeds (file exists on disk). Failure names the offending row.
- [ ] `zig build test` stays green after DOCCHECK-006 wires this file in.

**Implementation notes:**
- For Assertion A, sort both slices with `std.mem.sort([]const u8, ...)` using
  `std.mem.lessThan(u8, ...)`. Then diff for clear failure output.
- For Assertion E, access check is a runtime fs call — acceptable because it is
  a local path in the repo, not a network resource.
- Use `testing.allocator` throughout. All intermediate slices freed via `defer`.

---

### Phase 2 — Build wiring

#### DOCCHECK-006: Wire `tests/wpt_doc_check.zig` into `build.zig`

| Field | Value |
|---|---|
| **ID** | DOCCHECK-006 |
| **Title** | Add `test-doc` build step and wire under `zig build test` |
| **Depends On** | DOCCHECK-005 (file must exist before wiring) |
| **Files** | `build.zig` |
| **Estimated Time** | 15 min |
| **Complexity** | Low |

**Spec reference:** `specs/wpt-conformance-doc-hygiene/spec.md §5.3` bullet 3

**Acceptance criteria:**
- [ ] `const test_doc_step = b.step("test-doc", "Run §8 ↔ curated_cases doc-alignment check");`
      added alongside the other step declarations (line ~79 of `build.zig`).
- [ ] Module created with **no imports** — pure `std`, no C libs, no QuickJS:
      ```zig
      const doc_check_mod = b.createModule(.{
          .root_source_file = b.path("tests/wpt_doc_check.zig"),
          .target = target,
          .optimize = optimize,
      });
      ```
- [ ] `test_doc_step.dependOn(&run_doc_check.step)` wires the step.
- [ ] `test_step.dependOn(&run_doc_check.step)` makes it part of `zig build test`.
- [ ] `zig build test-doc` exits 0 with a passing run.
- [ ] `zig build test` still exits 0 (no regressions).

---

### Phase 3 — Spec and doc updates

#### DOCCHECK-007: Update `wpt-conformance.md §6` merge gates

| Field | Value |
|---|---|
| **ID** | DOCCHECK-007 |
| **Title** | Add `zig build test-doc` to §6 required commands |
| **Depends On** | DOCCHECK-006 |
| **Files** | `spec/subspecs/wpt-conformance.md` |
| **Estimated Time** | 5 min |
| **Complexity** | Low |

**Acceptance criteria:**
- [ ] `zig build test-doc` appears in the §6 command block.
- [ ] Rule 5 added: "`zig build test-doc` must stay green; §8 must mirror
      `curated_cases` at all times."

---

#### DOCCHECK-008: Update doc-hygiene spec to reflect closure

| Field | Value |
|---|---|
| **ID** | DOCCHECK-008 |
| **Title** | Update `specs/wpt-conformance-doc-hygiene/spec.md` to reflect enforcement landed |
| **Depends On** | DOCCHECK-006 |
| **Files** | `specs/wpt-conformance-doc-hygiene/spec.md` |
| **Estimated Time** | 10 min |
| **Complexity** | Low |

**Acceptance criteria:**
- [ ] §5.4 "Test commands (today)" updated to include `zig build test-doc`.
- [ ] §7 "Acceptance checklist" §8 mapping reconciliation checkbox marked `[x]`.
- [ ] Phase header updated from `specify` to `closed`.

---

## Dependency graph

```
DOCCHECK-001 ──┐
DOCCHECK-002 ──┤
               ├─ DOCCHECK-005 ─→ DOCCHECK-006 ─→ DOCCHECK-007
DOCCHECK-003 ──┤                                └─→ DOCCHECK-008
DOCCHECK-004 ──┘
```

All Phase 1 tasks (001–004) are independent and can be written in one pass.
DOCCHECK-005 integrates them. DOCCHECK-006 requires 005. 007 and 008 require 006.

---

## Verification

After all tasks complete, the following must all exit 0:

```bash
zig build test-doc      # new: doc-check passes
zig build test-wpt      # unchanged: 91 curated WPT cases
zig build test-test262  # unchanged: 46 curated Test262 cases
zig build test          # full suite including doc-check
```

Drift detection smoke-test (manual, before committing):
1. Add a fake filename to §8a in `wpt-conformance.md` — `zig build test-doc`
   should fail naming the extra entry.
2. Remove a filename from §8a — should fail naming the missing entry.
3. Change the header-note WPT count by 1 — should fail with count mismatch.
4. Restore and re-run — should pass.

---

## Files created or modified

| File | Action |
|---|---|
| `tests/wpt_doc_check.zig` | Create |
| `build.zig` | Modify: add `test-doc` step |
| `spec/subspecs/wpt-conformance.md` | Modify: §6 gate rule 5 |
| `specs/wpt-conformance-doc-hygiene/spec.md` | Modify: §5.4, §7 closure |
