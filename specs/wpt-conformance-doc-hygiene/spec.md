# WPT Conformance Doc Hygiene — Specification

> **Phase:** closed
> **Source plan:** `.opencode/plans/archive/1777340566199-calm-knight.md`
> **Closure authority:** `spec/subspecs/wpt-conformance.md` (this spec is an
> addendum that defines the doc-accuracy contract for §8 of that file)
> **Created:** 2026-05-01

---

## 1. Objective

`spec/subspecs/wpt-conformance.md §8` ("Mapping from API areas to test files")
is the human-readable mirror of the `curated_cases` array in
`tests/wpt_runner.zig` and the `curated_cases` array in
`tests/test262_runner.zig`. This spec defines the contract that keeps that
mirror accurate so reviewers, contributors, and downstream consumers can trust
§8 as a true index of shipped conformance coverage.

### Why this matters

§8 has already drifted in practice. At commit `70c6214` (HEAD on
2026-05-01) the doc states "84 active curated WPT cases" and "37 Test262
cases", which matches the committed runners. The working tree at
2026-05-01 already holds **91 WPT** entries (7 new fixtures staged but
unregistered in the doc) and **46 Test262** entries. Without an enforced
contract, drift is the default state.

### Measurable success criteria

A change is conformant with this spec if **all** of the following hold:

1. Every `.filename = "..."` value in `tests/wpt_runner.zig`'s `curated_cases`
   appears exactly once in either `§8a` (active) or `§8b` (deferred) of
   `spec/subspecs/wpt-conformance.md`.
2. Every entry listed in `§8a` or `§8b` corresponds to a file that exists
   under `tests/wpt/`.
3. The header note in `§8` states the correct counts (active WPT count,
   active Test262 count) for the current commit.
4. The Test262 case count in `§8a`'s "JS runtime" row matches the registered
   `curated_cases` count in `tests/test262_runner.zig`.
5. Any test file present in `tests/wpt/` but not registered in
   `curated_cases` is either listed in `§8b` with a blocking reason or is a
   harness/shim file that never registers (e.g. `testharness_shim.js`).
6. `zig build test-wpt` and `zig build test-test262` exit zero on the same
   commit that introduces or modifies §8.

---

## 2. Interface contracts

### 2.1. The `§8a` row schema

Each row in §8a's table has the form:

```
| <Area> | <comma-separated list of `filename.js` literals> |
```

- The `<Area>` column groups cases by the API surface they exercise.
  Reusing existing area names is preferred; new areas are added only when
  no existing row fits.
- The list cells use backticked filenames with `.js` extension, matching
  the `.filename` value in the corresponding `WptCase` literal.
- The "JS runtime" row terminates the table and records the Test262 count
  rather than enumerating filenames (Test262 cases are inline source, not
  files under `tests/`).

### 2.2. The `§8b` row schema

Each row in §8b's table has the form:

```
| <test file or planned filename> | <blocking gap, one sentence> |
```

- Filenames may refer to files that do not yet exist (planned-but-blocked
  cases). When that is the case the row must say "(not yet written)".
- The blocking gap must name a concrete prerequisite — a runtime feature,
  a harness shim, an upstream fixture — not a vague "TODO".

### 2.3. The header note

§8 begins with a status note of the form:

```
> **Current status (as of YYYY-MM-DD):** N active curated WPT cases pass
> via `zig build test-wpt`. M Test262 cases pass via `zig build
> test-test262`.
```

Where `N` and `M` are the commit-time counts of registered cases and the
date matches the commit (or PR merge) date.

### 2.4. Out-of-band notes (post-table prose)

§8 may include explanatory paragraphs after the table for cross-cutting
context (e.g. POST echo server, polyfill notes, integration-test bridges).
These are non-normative; the tables are the contract.

---

## 3. Project structure

### Files this spec governs

- `spec/subspecs/wpt-conformance.md` — the doc whose §8 is the contract
  surface. §1–§7 are out of scope for this spec.
- `tests/wpt_runner.zig` — source of truth for active WPT case set.
- `tests/test262_runner.zig` — source of truth for Test262 case set.
- `tests/wpt/*.js` — the WPT case fixtures themselves.

### Files this spec creates

- `specs/wpt-conformance-doc-hygiene/spec.md` — this file.
- *(optional, depends on §5 enforcement choice)* — a Zig test inside
  `tests/wpt_runner.zig` or a dedicated `tests/wpt_doc_check.zig` that
  asserts §8 ↔ `curated_cases` alignment.

### Files this spec must not touch

- `spec/MVP.md` — umbrella spec, not affected.
- `spec/subspecs/agent-browser.md`, `spec/subspecs/mvp-remainder.md` —
  cross-referenced from §8 prose but not governed here.
- `src/**/*.zig` — runtime code is unaffected.

---

## 4. Style and conventions

- **Filenames in the doc use backticks**, no surrounding quotes.
- **Order within an area row** matches the order of appearance in
  `curated_cases` (insertion order). When adding cases, append to the
  end of the matching row rather than alphabetizing.
- **Header note dates use ISO 8601** (`YYYY-MM-DD`).
- **Counts in the header note are explicit integers**, never approximated
  ("~80" is non-conformant; "84" is conformant).
- **Deferred entries always state the blocking gap.** A deferred row with
  only a filename is non-conformant.
- **Markdown tables stay on a single logical row each.** Long area lists
  may wrap visually but must not be split into multiple `|` rows for the
  same area.

---

## 5. Testing strategy

### 5.1. Enforcement is gated on MVP closure

Mechanical enforcement of the §8 ↔ `curated_cases` contract is **deferred
until the WPT, Test262, and remaining browser sub-specs have all reached
their closure state per `spec/MVP.md`**.

Rationale: while the curated corpus is still expanding (the working tree
on 2026-05-01 holds 7 unregistered WPT fixtures and 9 unregistered
Test262 cases), a strict markdown-parsing test would generate constant
false-friction PRs against the doc as cases land in batches. Enforcement
is most valuable *after* the corpus stabilizes, when drift is anomalous
rather than expected.

### 5.2. Pre-closure: convention-only

Until the closure gate fires, the contract is enforced by the rule
recorded in §6 ("Always do") of this spec and by the existing policy
in `spec/subspecs/wpt-conformance.md §7`. Reviewers are expected to
check that any change touching `curated_cases` in either runner also
updates §8 of `wpt-conformance.md` in the same PR.

This is known to have already drifted once (the current working tree).
Pre-closure drift is acceptable because reconciliation happens at
closure-gate time anyway.

### 5.3. At closure: mechanical enforcement lands

When `spec/MVP.md` declares MVP closure for WPT/Test262/browser
sub-specs, this spec gains a follow-on `plan.md` that implements:

1. A reconciliation pass that brings §8 fully in sync with the
   then-current `curated_cases` arrays in both runners.
2. A Zig doc-check test (location TBD at plan time —
   `tests/wpt_runner.zig` co-located vs. dedicated
   `tests/wpt_doc_check.zig`) that:
   - reads `spec/subspecs/wpt-conformance.md` via `@embedFile`,
   - extracts every backticked `*.js` filename from §8a and §8b,
   - asserts the active set equals `tests/wpt_runner.zig`'s
     `curated_cases.filename` set,
   - asserts the deferred set is disjoint from the active set and that
     every deferred filename either exists under `tests/wpt/` or is
     marked "(not yet written)",
   - asserts the header-note WPT count equals `curated_cases.len`,
   - asserts the header-note Test262 count equals
     `tests/test262_runner.zig`'s `curated_cases.len`.
3. Wiring of the doc-check into `zig build test` so drift fails CI on
   the same gate as the rest of the suite.

The implementation strategy (regex vs. hand-rolled scanner, exact
section anchor matching) is left to the future plan.

### 5.4. Test commands

The active gates (as of MVP closure):

```bash
zig build test-wpt        # all curated WPT cases pass
zig build test-test262    # all curated Test262 cases pass
zig build test-doc        # §8 ↔ curated_cases alignment check passes
zig build test            # full suite green (includes test-doc)
```

`zig build test-doc` runs `tests/wpt_doc_check.zig` — a pure-std Zig test
that reads the three repo files at runtime and asserts all five alignment
properties defined in §5.3. It has no C dependencies or network access.

---

## 6. Boundaries

### Always do

- Update §8 in the same change as any modification to either runner's
  `curated_cases` array.
- Update the header-note counts and date when the case set changes.
- Place new cases in §8a (active) or §8b (deferred), never both.
- Move a case row from §8b → §8a in the same commit that registers it
  in `curated_cases`.

### Ask first

- Before introducing a new `<Area>` row, confirm whether the case fits an
  existing area. New areas should reflect a genuinely new API surface,
  not finer-grained sub-categorization of an existing one.
- Before deleting a row from §8a, confirm whether the underlying case is
  being removed for cause (per `wpt-conformance.md §7`) or migrated to
  §8b (deferred).

### Never do

- Never add a `*.js` filename to §8 that does not exist on disk.
- Never list the same filename in both §8a and §8b.
- Never reorder existing entries within a row purely for aesthetic
  reasons (insertion order is part of the contract — see §4).
- Never approximate or "round" the header counts.
- Never edit `spec/subspecs/wpt-conformance.md` §1–§7 under cover of a
  §8 update; those sections have separate governance.

---

## 7. Acceptance checklist

This spec is **complete as a `specify`-phase artifact**. It does not need
a `/ai-eng-core:plan` follow-on yet. It graduates to `plan` only when
the closure gate fires — see §5.1.

### Gating signal — all gates fired (2026-05-02)

All four gating conditions from the original checklist are now met and
the mechanical enforcement has landed:

- [x] `spec/subspecs/wpt-conformance.md` declared closed in `spec/MVP.md`.
- [x] `tests/test262_runner.zig` at closure case count (46 cases).
- [x] All browser sub-specs at closure (`agent-browser.md` 2026-04-28,
      `rendering.md` 2026-04-30, `mvp-remainder.md` CLOSED).
- [x] §8 reconciled (`4336250`) and mechanical check lands in this commit.

### Enforcement status

`tests/wpt_doc_check.zig` is wired under `zig build test-doc` and `zig
build test`. `spec/subspecs/wpt-conformance.md §6` Rule 5 enforces it as
a merge gate. This spec is closed.

---

## 8. Open questions

These are reserved for the future `plan.md` and do not need to be
resolved during the specify phase:

1. Does the doc-check belong in `tests/wpt_runner.zig` itself
   (co-located, runs under `zig build test-wpt`) or in a dedicated
   `tests/wpt_doc_check.zig` that runs under `zig build test`? The
   former couples the doc check to WPT execution; the latter makes the
   doc check independent of network/JS engine state.
2. Should this contract eventually be lifted into `spec/subspecs/` as a
   first-class sub-spec, or stay in `specs/` as a feature-style spec?
   AWR's spec governance (`docs/adr/0001-spec-governance.md`) treats
   `spec/subspecs/` as closure authority; `specs/` is the
   `/ai-eng-core:specify` default but has no precedent in this repo.
3. Markdown-parsing approach for the doc-check: regex over embedded
   bytes vs. hand-rolled scanner vs. lifting the §8 table into a
   separate machine-readable file (e.g. `spec/subspecs/wpt-mapping.toml`)
   that the human-readable doc renders from. The third option avoids
   parsing markdown at all but introduces a new source of truth.
