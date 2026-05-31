# CSSOM Starter Sub-spec

Status: CLOSED 2026-05-27
Date: 2026-05-23
Authority: `SPEC.md` → `spec/MVP.md` → this file
Related: `spec/subspecs/browser-roadmap.md`, `spec/subspecs/wpt-conformance.md`, `docs/adr/0003-tier4-layout-strategy.md`

## 1. Scope

This sub-spec defines AWR's pre-layout CSSOM track. It exists to make CSS-visible browser APIs correct enough for scripts and terminal rendering decisions without claiming a full layout engine.

In scope:

- CSS resource loading:
  - `<style>` blocks;
  - `<link rel="stylesheet" href="...">`;
  - same URL resolution/fetch behavior as external scripts where practical.
- CSS declaration APIs:
  - `element.style`;
  - `CSSStyleDeclaration.cssText`;
  - `getPropertyValue(name)`;
  - `setProperty(name, value, priority)`;
  - `removeProperty(name)`;
  - property reflection for common camelCase properties.
- Author stylesheet rules:
  - parse into rule objects, not regex scans;
  - support simple selector lists through AWR's existing selector engine;
  - preserve source order.
- Cascade for the starter property set:
  - user-agent defaults;
  - author stylesheets;
  - inline styles;
  - specificity;
  - source order;
  - `!important`.
- `getComputedStyle(element)` for non-layout properties that AWR can compute deterministically.

Out of scope:

- full CSS parser coverage;
- layout tree / box tree construction;
- block/inline layout algorithms;
- flexbox, grid, floats, positioning, transforms;
- text shaping and font metrics;
- real scroll geometry;
- `getBoundingClientRect()` parity;
- geometry-backed `IntersectionObserver` / `ResizeObserver`.

Those remain Tier 4 per `docs/adr/0003-tier4-layout-strategy.md`.

## 2. Starter property set

The first computed-style properties should be small and terminal-useful:

| Property | Why |
|---|---|
| `display` | Controls visibility and future box generation. |
| `visibility` | Hides rendered output without removing DOM. |
| `white-space` | Controls terminal text wrapping/preservation. |
| `text-transform` | Affects displayed text deterministically. |
| `font-weight` | Maps to bold terminal styling. |
| `font-style` | Maps to italic/emphasis terminal styling where supported. |
| `color` | Maps to ANSI foreground color where safe. |
| `background-color` | Maps to ANSI background color where safe. |
| `text-decoration` | Maps to ANSI underline / strike-through. |
| `text-align` | Maps to terminal center/right alignment of single-line blocks. |

Properties may be added only with WPT coverage or a documented render/corpus test.

### 2.1 Post-closure additions (2026-05-31)

`text-decoration` and `text-align` were added to the computed-style set with
WPT coverage, and user-agent defaults for the emphasis/decoration/align
properties were extended so `getComputedStyle` reflects the same UA-stylesheet
values a real browser exposes to scripts (e.g. `strong`→`font-weight:bold`,
`em`→`font-style:italic`, `a`→`text-decoration:underline`,
`del`→`line-through`, `th`→`text-align:center`). These UA defaults mirror a
browser's UA stylesheet, independent of AWR's terminal presentation choices in
`src/render.zig` (which, for example, underlines headings). Coverage:
`tests/wpt/css_ua_text_defaults.js`. The renderer consumes the same properties
via its own in-module cascade resolver (`resolveCssProp` in `src/render.zig`),
gated on `ansi_colors` so the agent surfaces stay byte-identical.

Selector matching in the cascade was also corrected: compound (`div.foo`) and
combinator (`section p`, `ul > li`, sibling) selectors now match with proper
AND / ancestor semantics instead of the previous flat-OR approximation. The
parser flags such rules (`Rule.complex`) and the cascade matchers defer to the
full DOM selector engine (`dom.Element.matches`) for them, keeping the fast
pre-parsed path for single simple selectors. Coverage:
`tests/wpt/css_combinator_cascade.js`.

Attribute selectors are also honored in the cascade: the DOM selector engine
(`src/dom/node.zig`) gained the standard operators — `[attr]`, `[attr=v]`,
`[attr~=v]`, `[attr|=v]`, `[attr^=v]`, `[attr$=v]`, `[attr*=v]` — and the parser
flags `[...]` rules complex so the cascade routes them through that engine.
Coverage: `tests/wpt/css_attribute_selectors.js`.

## 3. Implementation shape

Move CSS behavior out of the JS bridge over time:

```text
src/cssom/
  style.zig         // CSSStyleDeclaration model (started)
  parser.zig        // stylesheet rule parsing (started -> pre-parsed selectors)
  cascade.zig       // specificity, importance, source order (started)
  computed.zig      // getComputedStyle property resolution (started -> resolved)
```

The JS bridge should become a thin adapter that calls this deterministic style engine instead of owning parsing/cascade logic in embedded JavaScript strings.

## 4. WPT growth plan

Add curated cases in this order:

1. Inline declaration basics:
   - `element.style.cssText`;
   - `getPropertyValue`;
   - `setProperty`;
   - `removeProperty`.
2. Stylesheet loading:
   - `<style>` block;
   - external `<link rel="stylesheet">`;
   - relative URL resolution.
3. Cascade basics:
   - stylesheet source order;
   - inline style wins over author stylesheet;
   - selector specificity.
4. `!important`:
   - author important beats normal inline only where spec says;
   - inline important precedence.
5. Computed style properties from §2.
6. Renderer integration:
   - `display:none` is not rendered; **started**
   - `visibility:hidden` is not rendered in the current terminal model; **started**
   - `white-space` affects wrapping/preservation.

## 5. Closure gates

This starter CSSOM track can be marked CLOSED when:

1. CSS parsing/cascade lives in a Zig `src/cssom/` module, not primarily in the bridge JS string.
2. Curated WPT cases cover §4 items 1–5.
3. Renderer/corpus tests cover §4 item 6.
4. `zig build test-wpt`, `zig build test-doc`, and relevant render tests are green.
5. `spec/MVP.md`, `SPEC.md`, `spec/subspecs/wpt-conformance.md`, and ADRs reflect the final closed scope.

## 6. Non-goals and guardrails

- Do not add layout-dependent WPT cases to this track.
- Do not expose geometry APIs as correct unless backed by Tier 4 layout.
- Do not let the CSSOM starter track silently become a layout engine.
- Prefer small, source-backed WPT slices over broad compatibility claims.

## 7. Closure record

CLOSED 2026-05-27. All §5 gates met:

1. **CSS parsing/cascade in Zig.** `src/cssom/{parser,style,cascade,computed}.zig`
   own stylesheet parsing, the `StyleDeclaration` model, specificity +
   precedence rules, and the high-level `StyleResolver`. The JS-side
   `__awr_apply_css_rules__` regex stylesheet parser and JS-side cascade in
   `src/dom/bridge.zig` were deleted; `getComputedStyle` is now a thin proxy
   that calls the native `__awr_css_get_computed_property__` (which uses the
   Zig cascade). Stylesheet registration goes via the native
   `__awr_css_register_stylesheet__`, which parses with
   `css_parser.parseStylesheet` and appends to `BridgeCtx.stylesheets`. The
   dom-aware glue (element-selector matching) lives in `bridge.zig`'s
   `ruleMatchesElement` so the `cssom/` modules stay dom-free.
2. **WPT §4.1–5 coverage.** Seven curated cases land §4 items 1–5:
   `css_style_declaration.js` (§4.1), `css_style_block.js` +
   `css_external_stylesheet.js` (§4.2), `css_cascade_basics.js` (§4.3),
   `css_important.js` (§4.4), `css_inline_computed_style.js` +
   `css_computed_properties.js` (§4.5). All green under `zig build test-wpt`.
3. **Renderer §4.6 coverage.** `display:none` and `visibility:hidden` covered
   by `render browse profile applies starter CSSOM display and visibility`
   in `src/render.zig`. `white-space: pre|pre-wrap|pre-line` covered by
   `render preserves whitespace under CSS white-space: pre / pre-wrap /
   pre-line`, also in `src/render.zig`. Renderer integration via
   `isCssWhiteSpacePreserved` reuses the existing `<pre>` `pre_depth`
   preservation path.
4. **Test gates green.** `zig build`, `zig build test-page`, `zig build
   test-wpt`, `zig build test-cssom`, `zig build test-tls`, `zig build
   test-h2` all green. TLS fingerprint and HTTP/2 SETTINGS unchanged.
5. **Canonical docs updated.** `spec/MVP.md`, `spec/subspecs/browser-roadmap.md`,
   `spec/subspecs/wpt-conformance.md`, and `docs/adr/0001-spec-governance.md`
   amended in the same change set.
