# AWR CLI Browser MVP Plan

## Goal

Turn AWR into a usable CLI-first MVP web browser.

The MVP is:
- open a site from the CLI
- execute enough browser behavior to load real page content
- render the page cleanly in the terminal
- follow internal links and crawl same-origin pages
- support basic interaction and event-driven flows
- use a curated WPT-first compatibility gate to prove browser behavior

The MVP is not:
- MCP-first
- WebMCP-first
- a full CSS/layout browser engine
- a claim of broad full-web compatibility

## Product Definition

Ship AWR as a CLI browser with these primary user flows:

1. `awr <url>` or `awr browse <url>` renders a readable page in the terminal.
2. Internal links can be followed reliably.
3. `awr crawl <url>` can enumerate and load same-origin pages with bounded limits.
4. Basic page interactions work through a CLI interaction surface.
5. The browser runtime is guarded by a curated WPT subset and a small Test262 subset.

## WPT-First Strategy

Use WPT-style tests as the main browser-compatibility gate for the MVP.

Do not attempt full upstream WPT coverage for this release.

The required gate is:
- `zig build test-wpt`
- `zig build test-test262`
- `zig build test-page`
- `zig build test-render`
- `zig build test-e2e`
- CLI fixture tests for browse, crawl, and interact

## Minimum Browser Subset For MVP

### Wave 1: DOM Read Surface

These must pass first.

- `document.title`
- `document.getElementById()`
- `document.querySelector()`
- `document.querySelectorAll()`
- selector support for:
  - `tag`
  - `#id`
  - `.class`
  - `tag#id`
  - `tag.class`
  - descendant selectors
  - basic attribute selectors needed by fixtures
- `Element.getAttribute()`
- `Element.hasAttribute()`
- `Element.textContent`
- `Element.querySelector()`
- `Element.querySelectorAll()`
- `matches()`
- `closest()`
- document-order results for `querySelectorAll()`

### Wave 2: DOM Identity And Mutation

These are required before real interaction work.

- stable node identity for repeated lookups
- real `parentNode`, `parentElement`, `children`, `childNodes`, `firstChild`, `lastChild`
- `contains()`
- `createElement()`
- `appendChild()`
- `removeChild()`
- `insertBefore()`
- `setAttribute()`
- `removeAttribute()`
- `className` / `classList` reflection
- `dataset` reflection for `data-*`
- DOM mutations visible to later queries and rendering

### Wave 3: Global And Async Browser Basics

- `window`
- `document`
- `globalThis === window`
- `window.location.href`
- `pathname`
- `search`
- `hash`
- `origin`
- `protocol`
- external script loading in document order
- relative script URL resolution
- `<base href>` support
- `Promise` microtask draining
- `setTimeout()`
- `clearTimeout()`
- microtasks before timers

### Wave 4: Fetch And State APIs

- `fetch()` Promise behavior
- `response.status`
- `response.ok`
- `response.text()`
- `response.json()`
- relative URL fetch
- basic rejection path
- `document.cookie`
- `navigator.cookieEnabled`
- in-memory `localStorage`
- in-memory `sessionStorage`
- `XMLHttpRequest` thin shim over the existing fetch path

### Wave 5: Event And Interaction Basics

This is the minimum event surface required to call it a browser rather than a static reader.

- `addEventListener()`
- `removeEventListener()`
- `dispatchEvent()`
- `.click()`
- simple bubbling from element to document
- `preventDefault()`
- input/change/click flows for fixtures
- basic form submit behavior for fixtures

## Recommended First WPT Expansion

Add these WPT-style curated tests first.

1. `document_querySelector_descendant.js`
2. `document_querySelectorAll_document_order.js`
3. `element_querySelector_scoped.js`
4. `element_querySelectorAll_scoped.js`
5. `element_matches_and_closest.js`
6. `dom_identity_same_lookup_same_object.js`
7. `dom_tree_relationships.js`
8. `dom_mutation_appendChild_reflected.js`
9. `dom_mutation_setAttribute_reflected.js`
10. `document_title_setter.js`
11. `classList_reflection.js`
12. `dataset_reflection.js`
13. `location_fields.js`
14. `fetch_relative_text_json.js`
15. `promise_and_timer_ordering.js`

Before adding async cases, extend `tests/wpt/testharness_shim.js` to support `promise_test(...)`.

## Minimal Test262 Guardrail

Keep this subset intentionally small.

Required language/runtime cases:
- `let` / `const` block scoping
- closures
- arrow functions
- destructuring
- template literals
- classes
- optional chaining
- nullish coalescing
- spread/rest
- default parameters
- `for...of`
- `Promise.then`
- `async/await`
- `try/catch/finally`
- `JSON.parse/stringify`
- `Object.keys`
- `Array.map/filter/find`

Rule: add Test262 cases only when they protect actual page execution or DOM bridge behavior.

## CLI-Specific Tests Beyond WPT

WPT is not enough to prove the CLI browser product.

Add fixture-based tests for:

### Browse / Render
- `awr <url>` prints readable output
- `awr browse <url>` loads and navigates links
- width wrapping via `--width`
- `--no-color`
- rendered content reflects post-JS DOM state
- links are surfaced predictably

### Interact
- click an element by selector
- type into an input by selector
- submit a form
- wait for timers/microtasks before reading output
- resulting DOM state is rendered back to terminal output

### Crawl
- same-origin only by default
- dedupe URLs
- ignore fragments
- bounded `--max-pages`
- bounded `--max-depth`
- session/cookie reuse across crawl
- output in text and JSON forms

Suggested fixture pages:
- `article_basic`
- `article_with_nav_noise`
- `script_bootstrap_inline`
- `script_bootstrap_external`
- `base_href_assets`
- `fetch_bootstrap`
- `event_click_reveal`
- `form_submit_search`
- `redirect_cookie_flow`
- `post_echo`

## Implementation Order

### Step 1: Harden The WPT Harness

Files:
- `tests/wpt_runner.zig`
- `tests/wpt/testharness_shim.js`

Work:
- support async `promise_test(...)`
- support local fixture HTTP responses where needed
- keep all cases curated and repo-local

### Step 2: Expand Selector And Query Support

Files:
- `src/dom/node.zig`
- `src/dom/bridge.zig`

Work:
- descendant selectors
- scoped element queries
- `matches()`
- `closest()`
- correct tree-order results
- stronger class matching behavior

### Step 3: Make DOM Objects Real Enough

Files:
- `src/dom/bridge.zig`
- `src/dom/node.zig`
- `src/page.zig`

Work:
- stable node identity
- parent/child relationships
- DOM mutation reflection back into the real Zig DOM
- post-JS rendering reads the mutated DOM

### Step 4: Lock Script And Async Execution

Files:
- `src/page.zig`
- `src/js/engine.zig`

Work:
- script ordering
- external script execution
- `<base href>` resolution
- microtask and timer ordering
- `clearTimeout()`

### Step 5: Add Fetch, Cookie, Storage, XHR Basics

Files:
- `src/js/engine.zig`
- `src/dom/bridge.zig`
- `src/client.zig`
- `src/net/cookie.zig`
- `src/page.zig`

Work:
- complete minimal `fetch()` shape
- `document.cookie`
- storage shims with real in-memory behavior
- XHR wrapper using the existing fetch path

### Step 6: Add Event And Form Basics

Files:
- `src/dom/bridge.zig`
- `src/page.zig`

Work:
- event listener registration
- dispatching and bubbling
- `.click()`
- form/input interaction sufficient for fixtures

### Step 7: Add CLI Interact And Crawl

Files:
- `src/main.zig`
- `src/browser.zig`
- `src/page.zig`
- supporting fixture tests

Work:
- introduce a minimal `interact` command or equivalent ordered-action CLI surface
- add a same-origin bounded `crawl` command
- reuse page state, cookies, and rendering where possible

### Step 8: Improve Rendering For Browser Use

Files:
- `src/render.zig`
- `src/browse_heuristics.zig`
- `src/browser.zig`

Work:
- ensure interactive content is visible
- preserve readability after JS mutation
- keep browse heuristics useful for site navigation

## Solo Task Breakdown

Plan-mode note: these are the repo-local solo tasks to create when execution starts.

1. Title: `Define CLI browser MVP and WPT gate`
   Priority: high
   Scope:
   - reframe docs away from MCP-first
   - define official MVP scope and test gates

2. Title: `Expand WPT harness for async fixtures`
   Priority: high
   Scope:
   - add `promise_test`
   - add fixture-server support if needed

3. Title: `Add WPT selector and query subset`
   Priority: high
   Scope:
   - descendant selectors
   - scoped queries
   - `matches` / `closest`

4. Title: `Make DOM mutation visible to queries and render`
   Priority: high
   Scope:
   - real node identity
   - mutation reflection
   - post-JS render correctness

5. Title: `Add WPT async and fetch subset`
   Priority: high
   Scope:
   - location
   - fetch
   - promises
   - timers

6. Title: `Implement cookie storage and XHR minimum`
   Priority: high
   Scope:
   - `document.cookie`
   - `localStorage`
   - `sessionStorage`
   - XHR shim

7. Title: `Implement event and interaction minimum`
   Priority: high
   Scope:
   - event listeners
   - click
   - form/input fixture support

8. Title: `Add CLI interact command and tests`
   Priority: high
   Scope:
   - selector-based actions
   - resulting page-state output

9. Title: `Add same-origin crawl command and tests`
   Priority: high
   Scope:
   - traversal
   - dedupe
   - bounds
   - JSON/text output

10. Title: `Update README and browser MVP docs`
    Priority: high
    Scope:
    - README
    - PRD
    - roadmap/plan docs
    - testing strategy doc

## Docs Update Plan

Update the repo to consistently describe AWR as a CLI browser MVP.

### Create or rewrite
- `README.md`
- `docs/testing.md` or equivalent

### Update existing docs
- `CLAUDE.md`
- `AGENTS.md`
- `spec/PRD.md`
- `MVP_PLAN.md`
- `MVP_ROADMAP.md`
- `PHASE1_EXIT_STATUS.md`
- `PHASE1_CLOSURE_PLAN.md`
- `PHASE2_START_PLAN.md`
- `spec/Phase1-Networking-TLS.md`
- `spec/Phase2-Plan.md`
- `spec/Phase3-Plan.md`

### Required doc changes
- remove phase framing from primary docs
- remove MCP-first framing from primary docs
- define the product as a CLI-first browser
- define WPT-first execution and the curated compatibility gate
- document supported commands and MVP test commands
- document explicit out-of-scope areas

## Verification

Minimum green bar for MVP work:

1. `zig build test-dom`
2. `zig build test-js`
3. `zig build test-page`
4. `zig build test-render`
5. `zig build test-wpt`
6. `zig build test-test262`
7. `zig build test-e2e`
8. CLI fixture coverage for browse, crawl, and interact

## Out Of Scope For MVP

- full CSS/layout conformance
- CSSWG suites
- WebDriver support
- full upstream WPT import
- canvas/webgl/audio APIs
- broad SPA/router/history correctness unless a fixture requires it
- MCP/WebMCP as ship-defining features

## Working Assumption

Use curated WPT-style browser tests to force the minimum browser behavior needed for a CLI web browser. Keep the scope intentionally narrow: browser enough to browse, crawl, and interact with pages from the terminal, without pretending to be a full graphical engine.
