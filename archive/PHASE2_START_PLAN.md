# Phase 2 Start Plan

## Current Read

Phase 2 foundations already exist, but Phase 2 is not meaningfully underway yet.

What already exists:

- `src/js/engine.zig`
  - QuickJS-NG integration
  - `console`
  - Promise draining
  - timer stubs
  - `fetch()` stub
- `src/html/parser.zig`
  - Lexbor wrapper + tests
- `src/dom/node.zig`
  - Lexbor -> Zig DOM conversion
  - `getElementById`, `querySelector`, `querySelectorAll`
- `src/dom/bridge.zig`
  - `document` bridge
  - `createElement`, `dataset`, `innerHTML`, event stubs
  - browser-ish globals like `navigator`, `location`, `screen`
- `build.zig`
  - QuickJS and Lexbor test targets already wired

## What Still Needs To Be Handled Before Phase 2 Is Really Started

### 1. Add a page/runtime orchestrator

There is no single runtime yet that does:

- fetch page HTML
- parse HTML
- build Zig DOM
- create JS engine
- install DOM bridge
- execute scripts in page order
- drain microtasks / manage runtime lifecycle

Without this, the current Phase 2 pieces are isolated modules, not a browser page pipeline.

### 2. Add script loading and execution flow

Missing pieces:

- inline `<script>` discovery and execution
- external `<script src>` loading
- base URL / `location` wiring for script resolution
- ordered execution semantics

This is the highest-value missing feature after the runtime shell.

### 3. Make DOM mutations real in the Zig DOM tree

Current bridge behavior is explicitly JS-only for mutations.

That conflicts with the Phase 2 milestone in `awr-spec/PRD.md:147`, which requires DOM mutations from JS to be reflected in the node tree.

Needed first-class mutation support:

- `createElement`
- `appendChild`
- `textContent`
- `innerHTML` (minimal safe implementation first)
- `dataset`

### 4. Replace Web API stubs with minimal working runtime APIs

Current gaps:

- `fetch()` is still a rejected Promise stub in `src/js/engine.zig`
- timers are no-op stubs
- no page-bound event/task scheduling
- no `URL` / `URLSearchParams` implementation found

Minimum Phase 2 target should be local-fixture correctness, not full browser completeness.

### 5. Add the missing HTML/CSS/resource pipeline pieces

Spec asks for:

- HTML/CSS parsing pipeline
- resource loading
- basic CSS cascade

Current repo has HTML parsing, but not a real CSS pipeline or page resource loader.

### 6. Add Phase 2 integration tests

Missing tests today:

- fetch -> parse -> bridge -> execute inline JS -> assert DOM mutation
- external script loading test
- page fixture with multiple scripts and microtasks
- milestone-style smoke tests for HN/Reddit behavior, gated until Phase 1 TLS is ready

## What Should Stay Blocked On Phase 1

Do not treat these as unblocked until TLS/curl-impersonate is actually working and validated:

- real-site HN/Reddit milestone validation
- external resource loading validation over the intended browser-fingerprint HTTPS path
- any claim that Phase 2 is complete

What can proceed now without waiting:

- local fixture-based page runtime work
- JS engine improvements
- DOM mutation reflection
- local script loading tests
- minimal fetch/URL APIs for local use

## Recommended First 3 Sessions

### Session 1: Build the page runtime

Add a module that composes:

- `Client.fetch`
- HTML parse
- DOM build
- JS engine init
- DOM bridge install

Scope:

- inline scripts only
- local HTML fixtures only

Success condition:

- one API can load fixture HTML and execute inline JS against a real bridged DOM

### Session 2: Make mutations reflect into Zig DOM

Replace the current JS-only fake mutation behavior with Zig-backed mutation operations.

Start with:

- `createElement`
- `appendChild`
- `textContent`
- `dataset`
- minimal `innerHTML`

Success condition:

- JS mutates DOM, and Zig queries see the mutation afterward

### Session 3: Add external scripts and minimal runtime APIs

Implement:

- `<script src>` loading
- base URL resolution
- minimal page-bound `fetch`
- minimal `URL` / `URLSearchParams`
- microtask/task handling good enough for startup bundles

Success condition:

- local multi-script fixtures execute in order and mutate DOM successfully

## Practical Bottom Line

To get Phase 2 started, the next missing thing is not another primitive module.
It is the orchestration layer that turns the existing JS + HTML + DOM pieces into a page runtime.

In short:

1. Build `Page`/runtime orchestration
2. Make DOM mutations real
3. Add script/resource loading
4. Then move to local fixture-based Phase 2 validation
5. Only after TLS is truly ready, move to HN/Reddit real-site milestone checks
