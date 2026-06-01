# Tier 4 LayoutAdapter Seam — Draft Proposal — 2026-06-01

> **Status:** Evidence artifact / DRAFT design for
> `docs/adr/0003-tier4-layout-strategy.md` §"Layout adapter direction" and
> evidence item 4 (prototype-result groundwork).
> **Read-only research. The Zig below is DRAFT TEXT in this doc only.**
> It is **not** wired into the live render path; no source file is changed and
> no behavior changes. Wiring it would require the ADR amendment ADR 0003
> demands.

## 1. Why a seam first (recap of ADR 0003)

ADR 0003 decided AWR should introduce a `LayoutAdapter` boundary **before**
choosing a backend, so the TUI and agent surfaces stay stable while three
implementations can be compared behind one contract:

```text
Page/DOM/JS runtime
    -> LayoutAdapter
        -> heuristic/no-layout adapter   (current behavior)
        -> external layout oracle adapter (POC)
        -> native Zig layout adapter      (future possible)
    -> terminal render model
    -> TUI / agent outputs
```

The companion audits
(`2026-06-01-tier4-wpt-delta-audit.md`,
`2026-06-01-tier4-target-site-audit.md`) found that AWR already produces
**terminal-cell geometry** today via `ScreenModel`/`rectForElement`
(`src/render.zig:240-277`), and that the layout-required surface is narrow
(pixel `getBoundingClientRect`, `IntersectionObserver`, `ResizeObserver`,
scroll geometry). The adapter's job is therefore **not** to replace the
renderer — it is to (a) name the geometry contract the renderer *already*
satisfies, and (b) make it swappable so a future oracle or native engine can
answer the same questions with higher (CSS-pixel) fidelity *without changing
any caller*.

## 2. Design constraints the seam must honor

1. **Default = current behavior, byte-for-byte.** The heuristic adapter must
   return exactly what `render.renderModel` produces today. The agent surfaces
   are byte-stable; the seam must not perturb them.
2. **Coordinate honesty.** The model must carry a `units` tag so a consumer
   knows whether boxes are terminal cells or CSS pixels. Today everything is
   cells; an oracle/native engine may answer in CSS px. We must never silently
   conflate them (this is the `getBoundingClientRect` weakness flagged in the
   WPT audit).
3. **Reuse existing types.** The contract should be expressed in terms of the
   existing `ScreenRect`/`ScreenBox`/`ScreenLink`/`ScreenField` so the
   heuristic adapter is a near-zero-cost wrapper, not a parallel model.
4. **No new network/fingerprint surface.** The adapter is layout-only. An
   external-oracle implementation must not be allowed to fetch — it receives
   already-fetched, already-parsed DOM + CSSOM and returns geometry only
   (ADR 0003: "external renderer only to answer layout/geometry questions
   first").
5. **Allocator-explicit, errdefer-clean.** Per `CLAUDE.md` code conventions.

## 3. Draft interface sketch (DOC-ONLY — not for wiring)

The proposal keeps the existing `ScreenModel` as the terminal render model and
introduces a thin adapter that *produces* it. The key additions are a `units`
discriminator and a vtable so the producer is swappable.

```zig
//! DRAFT — proposal text only. Not compiled, not imported.
//! Intended eventual home (when ADR 0003 is amended): src/layout/adapter.zig

const std = @import("std");
const dom = @import("dom/node.zig");
const render = @import("render.zig");
const cssom = @import("cssom/computed.zig");

/// Coordinate space of every rect in a LayoutModel. The whole point of the
/// tag is to stop callers from treating cell geometry as CSS-pixel geometry.
pub const Units = enum {
    /// Terminal character cells (current renderer behavior).
    terminal_cells,
    /// CSS reference pixels (oracle / native-layout adapters only).
    css_pixels,
};

/// Inputs the adapter is given. Note: NO client/socket — layout-only,
/// per ADR 0003. The DOM is already parsed; CSSOM is already cascaded.
pub const LayoutInput = struct {
    doc: *const dom.Document,
    /// Author + UA stylesheets, already parsed by src/cssom.
    stylesheets: []const cssom.Stylesheet,
    /// Terminal viewport in cells; css_px viewport = cols*8 x rows*16
    /// (mirrors the existing matchMedia convention in src/dom/bridge.zig).
    viewport_cols: usize,
    viewport_rows: usize,
    options: render.RenderOptions, // reuse existing options struct
};

/// The geometry contract every adapter returns. It is intentionally the
/// existing ScreenModel surface plus a units tag, so the heuristic adapter is
/// a pass-through and the agent/TUI byte output is unchanged.
pub const LayoutModel = struct {
    units: Units,
    /// Owned terminal render model — boxes/links/fields/lines already exist
    /// here today (src/render.zig ScreenModel). For css_pixels adapters the
    /// boxes carry CSS-px rects and the renderer maps them down to cells.
    screen: render.ScreenModel,

    pub fn deinit(self: *LayoutModel) void {
        self.screen.deinit();
    }

    /// Same lookup callers already use via ScreenModel.rectForElement,
    /// but the returned rect's coordinate space is self.units.
    pub fn rectForElement(self: *const LayoutModel, elem: *const dom.Element) ?render.ScreenRect {
        return self.screen.rectForElement(elem);
    }
};

/// The swappable seam. Three implementations populate `produceFn`.
pub const LayoutAdapter = struct {
    ptr: *anyopaque,
    produceFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, in: LayoutInput) anyerror!LayoutModel,
    /// Capability probe so the bridge knows whether to expose
    /// IntersectionObserver/ResizeObserver and css-px getBoundingClientRect.
    units: Units,

    pub fn produce(self: LayoutAdapter, gpa: std.mem.Allocator, in: LayoutInput) !LayoutModel {
        return self.produceFn(self.ptr, gpa, in);
    }
};
```

### 3.1 Heuristic / no-layout adapter (== current behavior)

```zig
//! DRAFT. Wraps the existing renderer; returns terminal-cell geometry.
//! This is the DEFAULT and must be byte-identical to today.
pub const HeuristicAdapter = struct {
    pub fn adapter(self: *HeuristicAdapter) LayoutAdapter {
        return .{ .ptr = self, .produceFn = produce, .units = .terminal_cells };
    }

    fn produce(_: *anyopaque, gpa: std.mem.Allocator, in: LayoutInput) !LayoutModel {
        // Exactly today's call. No behavior change.
        const screen = try render.renderModel(gpa, in.doc, in.options);
        return .{ .units = .terminal_cells, .screen = screen };
    }
};
```

This is the seam's safety guarantee: the default path is literally the current
`render.renderModel` call, so wiring the adapter in (later, under an amendment)
changes nothing observable.

### 3.2 External-oracle adapter (POC, throwaway)

```zig
//! DRAFT. POC ONLY. Sends DOM+CSSOM to an out-of-process layout oracle
//! (e.g. headless Chromium via CDP) and maps returned CSS-px boxes back into
//! a ScreenModel. NEVER fetches — the oracle is handed serialized DOM/CSS.
pub const OracleAdapter = struct {
    transport: OracleTransport, // JSON-over-stdio for the first POC (ADR 0003)

    fn produce(ptr: *anyopaque, gpa: std.mem.Allocator, in: LayoutInput) !LayoutModel {
        const self: *OracleAdapter = @ptrCast(@alignCast(ptr));
        // 1. serialize in.doc + in.stylesheets + viewport to JSON
        // 2. self.transport.request(...) -> CSS-px boxes/text-runs
        // 3. map CSS-px boxes -> ScreenBox/ScreenRect (css_px units)
        // 4. build a ScreenModel whose boxes are css_pixels
        _ = gpa;
        _ = self;
        return error.NotImplemented; // POC stub — proposal text only
    }
};
```

ADR 0003 says JSON-over-IPC is acceptable for the first prototype; binary
encodings wait until the contract is stable. The POC's only job is to prove the
adapter shape and produce *one* improved curated WPT/corpus case (evidence
item 4) — e.g. turn `intersection_observer.js` from a guard case into a passing
positive case, or make `element_bounding_client_rect.js` assert real CSS-px
coordinates.

### 3.3 Native-Zig adapter (future possible)

```zig
//! DRAFT. Future. A Zig layout engine consuming the SAME LayoutInput and
//! returning css_pixels boxes through the SAME LayoutModel. No new process,
//! no new dylib, no fingerprint surface (see resource/packaging audit).
pub const NativeAdapter = struct {
    fn produce(ptr: *anyopaque, gpa: std.mem.Allocator, in: LayoutInput) !LayoutModel {
        _ = ptr; _ = gpa; _ = in;
        return error.NotImplemented; // not built; 12-18 pm per roadmap §3
    }
};
```

## 4. How callers would migrate (later, under amendment)

Only two call sites need to change to adopt the seam, and both can default to
the heuristic adapter so nothing moves:

- `getBoundingClientRectFn` (`src/dom/bridge.zig:691`) currently calls
  `render.renderModel(...).rectForElement(elem)`. It would instead call
  `adapter.produce(...).rectForElement(elem)` and report the `units` tag.
- The TUI/agent render entrypoints that call `render.renderModel` directly
  would call `adapter.produce(...)` and keep using `.screen`.

`IntersectionObserver` / `ResizeObserver` exposure (the guard cases) would be
gated on `adapter.units == .css_pixels` (or on a richer capability flag), so
they stay un-exposed under the heuristic default and the no-stubs rule holds.

## 5. What this draft deliberately does NOT do

- It does **not** add a network path to any adapter (layout-only invariant).
- It does **not** change `ScreenModel`, `ScreenRect`, or any renderer code.
- It does **not** expose `IntersectionObserver`/`ResizeObserver`.
- It does **not** get imported, compiled, or wired anywhere. Activation is an
  ADR-0003-amendment decision, not a code-review decision.

## 6. Why this shape (tie-back to evidence)

- **Reuses `ScreenModel`** because the WPT delta audit showed AWR already has
  terminal-cell geometry; the adapter formalizes it rather than inventing a
  parallel model.
- **Carries a `units` tag** because the WPT audit's central finding is that
  AWR's current geometry is cells, not CSS px — the seam makes that explicit
  instead of pretending.
- **Defaults to a pass-through heuristic adapter** because the site audit found
  the target readable web needs no layout; the default must cost nothing.
- **Treats the oracle as a throwaway POC** because the packaging audit found
  Path A (Chromium) is the worst packaging/sandbox/fingerprint fit — fine for
  de-risking the contract, wrong as a shipped backend.
- **Leaves room for a native adapter** because the packaging audit found Path C
  best preserves AWR's identity *if* demand ever justifies its up-front cost.
