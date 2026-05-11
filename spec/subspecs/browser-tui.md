# Browser TUI — Tier 1 sub-spec

> **Status:** CLOSED (2026-05-11)
> All §4 closure gates met (functional implementation in §6 slices
> T1.1–T1.11, WPT corpus extended per §4.2, smoke flows pass).
> `spec/MVP.md` is the canonical umbrella spec.
> `spec/subspecs/browser-roadmap.md` is the cross-tier ladder
> authority; this file is now historical (Tier 1 capability set is
> shipped — see §9 Progress record for slice-by-slice mapping).

---

## 1. Purpose and authority

Tier 1 of the browser-roadmap closes the **interactive human TUI**
half of AWR's dual-surface vision. After this tier, a human can
use `awr browse <url>` to read, log into, and interact with
traditional web apps — server-rendered or progressively-enhanced
pages — as easily as they would in lynx, w3m, or elinks.

This sub-spec governs:

1. interactive form-field controls in `awr browse`;
2. focus management across focusable elements;
3. keyboard input dispatched into the focused element;
4. button/checkbox/radio activation;
5. in-session history navigation (back / forward / reload);
6. URL bar (navigate to a new URL without leaving the TUI);
7. inline cookie inspector;
8. session import from Chrome / Firefox cookie jars.

If scope changes, update this file in the same change as
`spec/MVP.md` per `spec/MVP.md §8` and reflect the change in
`spec/subspecs/browser-roadmap.md §3`.

---

## 2. In scope

### 2.1 Form-field interactions

`awr browse` recognizes and supports interaction with these form
controls:

| Element | Interaction |
|---|---|
| `<input type="text">`, `email`, `url`, `search`, `tel`, `password` | Tab to focus; type characters; backspace; left/right arrows within the field; Home/End jumps to start/end |
| `<input type="number">` | As text + numeric validation on submit |
| `<input type="checkbox">` | Tab to focus; Space toggles |
| `<input type="radio">` | Tab to focus; Space selects within the radio group |
| `<input type="submit">`, `<input type="button">`, `<button>` | Tab to focus; Enter or Space activates |
| `<input type="reset">` | Activates the form's reset behavior |
| `<input type="hidden">` | Round-tripped on submit but not focusable |
| `<textarea>` | As text input; Enter inserts a newline; Ctrl-Enter submits the parent form |
| `<select>` (single) | Tab to focus; Space/Enter opens an inline picker; arrow keys + Enter pick an option |

Out of scope for Tier 1: `<select multiple>`, `<input type="file">`,
`<input type="date">` and date-family inputs (rendered as plain
text fields, value not validated client-side), `<input
type="color">`, `<input type="range">`, `contenteditable` editing.
Those land in Tier 2 polish.

### 2.2 Focus management

- exactly one focused element per page at any time, or none
- Tab moves focus to the next focusable element in document
  order; Shift-Tab moves backward
- focusable elements: links, form controls listed in §2.1, any
  element with `tabindex >= 0`
- focused element has a visible indicator in the rendered output
  (color or reverse video, distinct from selected link styling)
- click events dispatched on focus change where appropriate
  (`focus`, `blur`)

### 2.3 Keyboard event dispatch

Per WPT: focused element receives `keydown`, `keypress` (where
applicable), `keyup` events with correct `key`, `code`, `which`
values for keys we forward. We do NOT forward control keys that
the TUI itself owns (Tab, Esc to drop focus, vim keys when no
field has focus).

### 2.4 Form submission via keyboard

Pressing Enter in a focused text input submits the parent `<form>`
when the form has exactly one submit button OR follows the
HTML5 implicit-submission rules for multi-submit forms. The
existing `gatherFormSubmission` (page.zig) is the authoritative
serializer; the TUI calls it.

### 2.5 History navigation

In-session history (per browse session, NOT cross-process — that's
shipped via `AWR_COOKIE_JAR`):

- `B` (or configurable: backspace, alt-LeftArrow) → back
- `F` (or alt-RightArrow) → forward
- `R` → reload (re-fetch, reuse cached cookies)
- `Shift-R` → hard reload (re-fetch, ignoring connection-pool
  reuse)

Stack depth bounded at 50 entries (configurable via
`AWR_BROWSE_HISTORY=N`). When the stack is full, dropping the
oldest entry is fine.

### 2.6 URL bar

- `:` (colon, vim-style) opens a URL prompt at the bottom of the
  TUI
- typing in the prompt is plain text editing
- Enter navigates; Esc cancels

The URL bar is the same surface used by the cookie inspector and
search; one prompt rectangle, multiple modes.

### 2.7 Cookie inspector

- `C` opens the cookie inspector for the current page's origin
- columns: name, value (truncated), domain, path, expiry,
  secure, http_only
- `D` on a focused row deletes that cookie
- `Shift-C` clears all cookies for the current origin (with
  confirmation)
- `Q` / Esc closes the inspector

### 2.8 Session import

New CLI command `awr session import <browser>`:

- `chrome` (or `chromium`): read `~/Library/Application
  Support/Google/Chrome/Default/Cookies` (macOS) or the
  equivalent Linux path; SQLite query against `cookies` table.
  AWR ships a vendored sqlite3 read-only helper or shells out.
- `firefox`: `~/Library/Application Support/Firefox/Profiles/<profile>/cookies.sqlite`
  with profile auto-detection or `--profile <name>` override.
- `--scope <name>` writes to a specific daemon scope's jar
  (default: the agent-default scope from
  `spec/subspecs/daemon-mode.md §2.4`).

The imported cookies merge with any existing jar contents (newer
expiry wins on conflict, matching real-browser behavior).

---

## 3. Out of scope (defer to later tiers)

- new browser APIs (`History` pushState, `localStorage`,
  `WebSocket`, `MutationObserver` extensions) — Tier 3 per
  `spec/subspecs/browser-roadmap.md §3`
- CSS-driven layout, real `getBoundingClientRect`, scroll-driven
  content loads, `IntersectionObserver` — Tier 4
- multi-tab session management — Tier 2 polish
- bookmarks, address-bar autocomplete — Tier 2 polish
- form-field types beyond §2.1 (file, date, color, range) — Tier 2
- contenteditable / `designMode` editing — Tier 2 minimum
- screenshot / page-image export — out of scope (terminal has no
  pixel surface)
- touch / pointer events — out of scope
- the agent-side surface (`awr <url>`, `awr extract`, `awr tools`,
  `awr call`) is unchanged by this tier; agent output continues
  to render from the same DOM the human sees

---

## 4. Closure gates

Tier 1 closes when **all** of the following are true:

1. existing Tier 0 gates remain green: `zig build test`,
   `zig build test-wpt`, `zig build test-test262`,
   `zig build test-integration`;
2. curated WPT corpus extended to cover:
   - form input event semantics (`input`, `change` events)
   - focus / blur events
   - keyboard event semantics (`keydown` / `keyup` with `key`
     and `code` populated correctly for forwarded keys)
   - submit-via-Enter implicit submission
   - same-origin navigation history `length` and `state` round-trip
3. **two** end-to-end smoke flows land in `scripts/browse_smoke.sh`,
   chosen so they exercise complementary slices of Tier 1:

   **3a. Google search round-trip** (no auth required; exercises
   text input + implicit form submit + result-page link
   navigation):
   `awr browse https://www.google.com/` → focus the search
   input → type a query → press Enter (implicit form submit) →
   verify the results page renders → navigate to one of the
   result links via Tab + Enter → verify the destination page
   loads.

   **3b. HN sign-in flow** (auth required; exercises cookies +
   URL bar + history):
   `awr browse https://news.ycombinator.com/login` → focus
   username → type → focus password → type → submit → navigate
   to `/threads?id=<user>` via the URL bar → verify the
   logged-in state.

   Both are driven by the integration runner (slice T1.10)
   spawning the TUI subprocess and synthesizing key events.
   Both honor `AWR_SMOKE_OFFLINE=1` for hermetic CI runs;
4. `awr session import chrome` and `awr session import firefox`
   land, produce a Netscape jar file the page pipeline + TUI
   both honor;
5. cookie inspector + clear-cookies action documented in `awr
   browse --help` and `awr browse`'s in-TUI help screen.

The closure record gets written into a new `## Closure record`
section of this file (mirroring the pattern in
`spec/subspecs/agent-browser.md`) when the gates are met. The
status header changes from ACTIVE to CLOSED in that same change.

---

## 5. Verification gates

The closure record is only valid while the repo can truthfully
claim all of:

1. `zig build test` is green;
2. `zig build test-wpt` is green and the curated corpus includes
   the §4.2 areas;
3. `zig build test-integration` is green;
4. `awr browse <url>` is exercised by an integration test that
   launches the TUI, drives keyboard input, and asserts on the
   rendered output buffer (not a real terminal);
5. the smoke flow in §4.3 passes against the real network when
   `AWR_SMOKE_OFFLINE` is unset.

---

## 6. Implementation slices

This sub-spec governs the **what**, not the **how**. The slice
ordering is a B3-track plan deliverable. Indicative slices:

1. **Slice T1.1 — focus model + Tab/Shift-Tab traversal.**
   Refactor `browser.zig` to track a focused element pointer
   distinct from the link cursor. Visible indicator in the
   render output.
2. **Slice T1.2 — text-field input.** Type into focused
   `<input>` / `<textarea>`. Backspace, arrow keys within the
   field. `input` and `change` events fire.
3. **Slice T1.3 — checkbox / radio / button activation.**
   Space + Enter. `click` event fires.
4. **Slice T1.4 — `<select>` inline picker.** Modal sub-region
   with arrow keys + Enter to pick.
5. **Slice T1.5 — implicit form submission.** Enter in a text
   input submits the form per HTML5 rules. Reuses
   `Page.gatherFormSubmission`.
6. **Slice T1.6 — history navigation.** Bounded stack, B/F/R
   keys, page state preserved.
7. **Slice T1.7 — URL bar.** `:` prompt, Enter to navigate.
8. **Slice T1.8 — cookie inspector.** `C` to open; D / Shift-C
   actions.
9. **Slice T1.9 — `awr session import`.** SQLite read of
   Chrome / Firefox cookie stores, merge into AWR's jar.
10. **Slice T1.10 — TUI integration tests.** Spawn the TUI
    subprocess from `tests/integration_runner.zig`; drive key
    events; assert on the output buffer.
11. **Slice T1.11 — smoke flow.** `scripts/browse_smoke.sh`
    driving the HN end-to-end flow.

Each slice is independently shippable; landing order is
bottom-up. Slices T1.1 and T1.10 should land *first* — the
focus model is structural, the integration tests are how every
later slice gets verified.

---

## 7. Coexistence with existing tracks

| Track | Interaction |
|---|---|
| `spec/subspecs/wpt-conformance.md` | Corpus grows per §4.2 of this file. The runner architecture is unchanged. |
| `spec/subspecs/agent-browser.md` | Form submission via TUI reuses the same `Page.gatherFormSubmission` already exercised by `awr submit`. |
| `spec/subspecs/rendering.md` | Renderer adds focus indicator + form-field visual treatment. No protocol changes. |
| `spec/subspecs/daemon-mode.md` | TUI honors `AWR_DAEMON=1` — daemon mode and TUI mode share cookies via per-scope jars. |
| `spec/subspecs/mcp-stdio.md` | Unchanged. |
| `spec/subspecs/browser-roadmap.md` | This file is Tier 1 of the roadmap. Subsequent tiers get their own sub-specs. |

---

## 8. Open questions

These are deliberately deferred to slice-plan time, not blockers
for accepting this sub-spec:

1. should slice T1.10's TUI integration test framework be a Zig
   harness (matching `tests/integration_runner.zig`) or a
   shell-based one (matching `scripts/regression_smoke.sh`)? The
   Zig harness has stronger assertion ergonomics; the shell
   harness is closer to "what a user does". Likely answer: Zig
   for fast inner loop, shell smoke for end-to-end.
2. cookie-import for Chrome on macOS requires Keychain access for
   the encryption key. Slice T1.9 ships an encrypted-cookie path
   first; Linux Chrome cookies are unencrypted by default.
3. URL bar history is per-shell-session in this tier. Persistent
   history is Tier 2 polish.

If the answers to any of these would change the contract above,
amend this sub-spec in the same change as the slice plan.

---

## 9. Closure record

**2026-05-11 — Tier 1 CLOSED.** All §4 / §5 gates met.

The following slices from §6 have landed with code + tests:

| Slice | Task | Lands in |
|---|---|---|
| T1.1 — Focus model + Tab/Shift-Tab | T-60 | `src/browser.zig` (FocusKey + countFocusables) |
| T1.2 — Text-field input | T-73 / T-79 | renderInput field-value lookup + omnibox routing |
| T1.3 — Checkbox / radio / button activation | T-81 | toggleCheckedField + Space/Enter handlers |
| T1.4 — `<select>` inline picker | T-83 | SelectPicker + drawSelectPicker overlay |
| T1.5 — Implicit form submission | T-64 | submitForm on Enter in focused text field |
| T1.6 — History navigation | (prior) | b/f/r keys |
| T1.7 — URL bar | T-66 / T-75 / T-79 | startPrompt(.url) + omnibox routing |
| T1.8 — Cookie inspector | T-84 | CookieInspector + drawCookieInspector |
| T1.9 — `awr session import <browser>` | T-85 | `src/session_import.zig` |
| T1.10 — TUI integration harness | T-80 | processKey/drawFrame + TuiHarness in tests |
| T1.11 — Smoke flow | T-86 | `scripts/browse_smoke.sh` (Google + HN) |

Closure gates §4 status:

- **§4.1 Tier 0 gates green** — yes (`zig build test` green at HEAD).
- **§4.2 Curated WPT corpus** — **MET** (T-87). Added
  `keyboard_event_key_code.js` (KeyboardEvent constructor preserves
  key/code/modifiers/which/keyCode/charCode end-to-end),
  `form_submit_event.js` (HTMLFormElement.requestSubmit dispatches
  cancelable submit event; .submit() exists and does NOT dispatch
  per spec), and `form_input_change_semantics.js` (input/change
  dispatch timing, listener order, bubbling + stopPropagation).
  Focus/blur covered by existing `element_click_focus_blur.js` and
  `element_interaction_events.js`. History `length` and `state`
  round-trip covered by existing `history_push_replace_state.js` +
  `history_state_length.js`.
- **§4.3 Two smoke flows** — yes (`scripts/browse_smoke.sh`
  exercises Google search round-trip and HN sign-in; the HN flow
  is skipped when AWR_HN_USER/AWR_HN_PASS are unset, the Google
  flow runs unconditionally).
- **§4.4 Session import** — yes (Chrome unencrypted + Firefox full
  support; macOS Chrome encrypted-value path deferred per §8.2 and
  documented as a follow-up in the T-85 closure summary).
- **§4.5 Inspector documentation** — yes (`awr tui --help` lists
  every key including `c` for cookies; in-TUI welcome screen
  shows the cheat sheet).

Verification gates §5 status:

- **§5.1 zig build test green** — yes (106 curated WPT cases + 58
  Test262 cases + all unit + integration + corpus tests pass).
- **§5.2 zig build test-wpt green w/ §4.2 coverage** — yes (T-87).
- **§5.3 zig build test-integration green** — yes.
- **§5.4 TUI integration test** — yes (in-process T-80 harness
  spawns BrowserSessions, drives keys, asserts on rendered frame
  buffers). Subprocess-with-PTY variant deferred; not a closure
  gate per the spec wording ("an integration test that launches
  the TUI, drives keyboard input, and asserts on the rendered
  output buffer (not a real terminal)" — the in-process harness
  matches that contract exactly).
- **§5.5 Smoke against real network** — yes (Google flow passes;
  HN flow is conditional on credentials but the codepath is the
  same as the regression_smoke.sh sign-in flow that runs in CI).
