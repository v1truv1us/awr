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

### 2.2 Computed-value serialization (2026-05-31)

`getComputedStyle` now returns the *resolved* form a real browser exposes to
scripts, not the authored token: `font-weight: bold` → `"700"` /
`normal` → `"400"`, and `color` / `background-color` keywords, `#hex`, and
`rgb()` → `"rgb(r, g, b)"` (or `"rgba(…)"` when alpha < 1). Serialization is
applied only at the `getComputedStyle` boundary (`__awr_canon_computed__` in
`src/dom/bridge.zig`); `element.style.*` (the inline `CSSStyleDeclaration`)
keeps the authored value, and the renderer maps raw author values to ANSI
independently, so the agent/corpus surfaces are unaffected. Coverage:
`tests/wpt/css_computed_value_serialization.js` plus updated assertions across
the existing CSS cases.

### 2.3 Compiled-selector cache + exact renderer matching (2026-05-31)

`src/dom/node.zig` exposes its selector engine (`compileSelectorList`,
`matchesCompiled`, `pub SelectorList`) so cascades can compile each rule's
selector once and match many elements without re-parsing. The renderer
collects only the *text* rules (those mapping to ANSI) in cascade order,
pre-compiles their complex selectors, and resolves all text properties in a
single matching pass per element — so it now applies compound/combinator/
attribute selectors **exactly** (e.g. `.box p { color }` styles only
descendants) instead of the previous flat-OR approximation. Exact matching
walks the ancestor chain, so it is gated: a page with more than 48 complex
text rules (MediaWiki-scale) falls back to the flat approximation to stay
within the render time budget. The script-facing `getComputedStyle` cascade is
always exact. Covered by an inline `src/render.zig` test plus the unchanged
`css_combinator_cascade.js` / `css_attribute_selectors.js` getComputedStyle
cases.

### 2.4 Structural pseudo-classes (2026-05-31)

The selector engine (`src/dom/node.zig`) implements the structural
pseudo-classes `:first-child`, `:last-child`, `:only-child`, `:nth-child(an+b)`
(incl. `odd`/`even`), and the of-type variants `:first-of-type`,
`:last-of-type`, `:only-of-type`, `:nth-of-type(an+b)`. The parser flags
`:`-bearing rules complex so the cascade routes them to the engine, and
unsupported pseudo-classes (state pseudos like `:hover`, pseudo-elements
`::before`) mark the selector non-matching so such rules don't over-apply.
Coverage: `tests/wpt/css_structural_pseudo.js`.

### 2.5 @media in the cascade (2026-05-31)

`cssom/parser.zig` no longer skips `@media` blocks: it brace-matches the block,
parses the nested rules, and tags each with its media condition
(`Rule.media`). Cascades (the renderer and getComputedStyle) skip a rule when
its condition does not match the viewport, evaluated by `parser.mediaMatches`
— a Zig port of the `matchMedia` model (`src/js/engine.zig`): comma = OR,
`and` = AND of parenthesized features; supports `(min|max)-width`,
`(min|max)-height` (viewport ≈ columns × 8 / rows × 16 CSS px),
`prefers-color-scheme` (terminal default dark), and the `screen`/`all` media
types. Coverage: `tests/wpt/css_media_cascade.js`.

### 2.6 Shorthand longhands + CSS-wide keywords (2026-05-31)

`getComputedStyle` exposes longhands extracted from shorthands
(`text-decoration` → `text-decoration-line`; `font` → `font-style` /
`font-weight`) via `declValueForProp` in `src/dom/bridge.zig`, and resolves the
CSS-wide keywords `inherit` / `initial` / `unset` at the proxy boundary against
a small property metadata table (initial value + whether the property
inherits; `unset` = inherit for inherited properties, initial otherwise).
`inherit`/inherited-`unset` read the parent's computed value recursively.
These act only on the script-facing getComputedStyle surface; the renderer
reads the `text-decoration` shorthand directly and is unaffected. Coverage:
`tests/wpt/css_wide_keywords.js`.

### 2.7 Color serialization completeness (2026-05-31)

The getComputedStyle color serializer (`__awr_serialize_color__` in
`src/dom/bridge.zig`) covers the full CSS extended named-color set, `hsl()` /
`hsla()` (converted to `rgb()` / `rgba()`), `transparent` →
`rgba(0, 0, 0, 0)`, and `currentColor` (resolves to the element's computed
`color`; inherits on the `color` property itself). Coverage:
`tests/wpt/css_color_serialization.js`.

### 2.8 Selector functions `:not()` / `:is()` / `:where()` (2026-06-01)

The DOM selector engine (`src/dom/node.zig`) implements the functional
pseudo-classes `:not()`, `:is()`, `:where()` with full selector-list
arguments (e.g. `:not(.a, .b)`, `:is(h1, h2, .title)`, `:where(#box) .item`).
An element matches `:is()` / `:where()` when **any** argument matches and
`:not()` when **none** match; each argument is a compound simple selector
(combinators inside arguments are out of non-layout scope). The previous
single-simple-selector `:not()` representation was replaced by a
`FuncPseudo` list so multiple functional pseudos can co-exist on one compound
selector, and the leaked-on-failure `:not` allocation path was removed. The
parser already flags `:`-bearing rules `complex`, so the cascade routes these
to the engine. Specificity (CSS Selectors §16) is computed in
`Specificity.calculate` (`src/cssom/cascade.zig`): `:where()` contributes 0;
`:is()` / `:not()` take the specificity of their most-specific argument.
Coverage: `tests/wpt/css_selector_functions.js` plus co-located dom/cascade
tests.

### 2.9 Custom properties + `var()` substitution (2026-06-01)

CSS custom properties (`--foo` declarations) parse as ordinary declarations
through the existing `StyleDeclaration` model and resolve through the Zig
cascade. Custom properties **inherit**, and `var(--foo, fallback)` references
are substituted, both at the getComputedStyle boundary in `src/dom/bridge.zig`
(`__awr_custom_prop__` walks the parent chain for inheritance;
`__awr_substitute_var__` replaces `var()` references with the resolved
custom-property value or the fallback). This stays non-layout: it acts only on
the script-facing getComputedStyle surface, so the renderer's own Zig cascade
and the agent/corpus byte output are unaffected. Coverage:
`tests/wpt/css_custom_properties.js`.

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
