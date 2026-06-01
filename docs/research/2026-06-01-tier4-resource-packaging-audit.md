# Tier 4 Resource & Packaging Audit — 2026-06-01

> **Status:** Evidence artifact for `docs/adr/0003-tier4-layout-strategy.md`
> §"Required evidence before final Tier 4 decision", item 3 (resource and
> packaging audit). **Read-only research.** No spec/ADR amended, no source
> behavior changed.

## Method

Facts pulled from `CLAUDE.md`, `build.zig`, `build.zig.zon`, `third_party/`,
and `otool -L` on the built binary. Estimates are clearly labeled as estimates.

## 1. Current packaging baseline (what Tier 4 would perturb)

### Binary and dependency footprint

| Component | Linkage today | Size | Source |
|---|---|---|---|
| `awr` binary | — | 13.2 MB | built this audit |
| `awrd` daemon | — | 11.3 MB | built this audit |
| BoringSSL | **static** (vendored `.a`) | libcrypto 16 MB + libssl 12 MB archives → linked subset in binary | `third_party/boringssl/lib/macos-arm64/` |
| lexbor (HTML parser) | **dynamic** from Homebrew | `liblexbor.3.dylib` 3.0 MB | `otool -L`; `build.zig:155-157` |
| nghttp2 (HTTP/2) | **dynamic** from Homebrew | `libnghttp2.14.dylib` ~196 KB | `otool -L`; `build.zig:47-51` |
| QuickJS-NG | static (Zig pkg, `use_llvm=true`) | vendored src 32 MB tree | `third_party/quickjs-ng-quickjs` |
| libxev | static (Zig pkg) | 3.1 MB tree | `third_party/libxev` |
| stb_image | static (vendored C TU) | 284 KB | `third_party/stb` |
| CA bundle | data file | 224 KB | `third_party/ca-bundle` |

**Critical finding for the single-binary claim:** AWR is described as "one
binary" in `CLAUDE.md`, but it is **not** self-contained today — lexbor and
nghttp2 are dynamically linked from `/opt/homebrew`. The product is already a
"single binary + two Homebrew dylibs on the documented dev platform"
(macOS/arm64). The single-binary *requirement* is therefore **aspirational and
platform-scoped**, not an invariant Tier 4 must preserve byte-for-byte.

### Platform scope

`CLAUDE.md` Critical Constraint #2 and `build.zig:33` hardcode
`/opt/homebrew` paths: **macOS/arm64 is the only supported platform**;
cross-platform is "a future concern". BoringSSL is vendored as a macos-arm64
`.a` only (`build.zig:66-69`). So today there is **no sandboxing story and no
multi-platform packaging story** — the binary trusts the host, links host
dylibs, and ships for one OS/arch.

### Source size

`src/` is ~37.8 kLoC of Zig. The renderer is `src/render.zig` (4.3 kLoC); the
entire non-layout CSSOM track is `src/cssom/*.zig` (≈800 LoC across
parser/cascade/computed/style). For comparison, even a *minimal* CSS layout
engine is estimated at 12-18 person-months in `browser-roadmap.md §3` — i.e.
the layout engine alone would rival or exceed the current whole-project Zig
surface in complexity.

## 2. Single-binary requirement strength

How load-bearing is "single binary" to AWR's identity?

**Arguments that it is strong:**
- `CLAUDE.md` repeatedly frames AWR as "one binary, two co-equal interfaces"
  and lists "single Zig binary vs bundled renderer dependency" as a core
  identity question (ADR 0003 Context).
- Fast startup + daemon amortization (`spec/subspecs/daemon-mode.md`) is a
  product feature; a heavy renderer process undercuts it.
- The Chrome-shaped fingerprint lives in AWR's own net stack
  (`src/net/fingerprint.zig`); an embedded browser would bring its *own*
  network stack and fingerprint, fragmenting the product's core value
  (Critical Constraint #1).

**Arguments that it is weaker than stated:**
- AWR already ships with two runtime dylib dependencies (lexbor, nghttp2). The
  "single binary" is already a polite approximation.
- A daemon (`awrd`) already exists as a second long-lived process. Adding one
  more out-of-process helper (a layout oracle) is not a category change in the
  way the marketing implies — it is the *third* process, after `awr` and
  `awrd`.

**Net read:** the single-binary requirement is real for the *core runtime*
(fetch/DOM/JS/cookies must stay AWR-owned to protect the fingerprint and shared
session), but it is **already relaxed for ancillary helpers**. An
*out-of-process layout oracle* that does not touch the network is the least
disruptive way to add layout, because it doesn't fragment the fingerprint-
bearing runtime.

## 3. Packaging / sandboxing implications per Tier 4 path

Using ADR 0003's three options (A embed-oracle/Chromium-CDP, B Servo/LibWeb
hybrid, C native-Zig).

### Path A — external layout oracle (e.g. headless Chromium via CDP)

- **Packaging:** must ship or locate a full Chromium (~150-200 MB) or depend on
  a system Chrome. Either bloats the install by ~15× the current binary or adds
  a hard external runtime dependency. Breaks the "drop one binary" story
  hardest.
- **Sandboxing:** Chromium *requires* a sandbox (seccomp/namespaces on Linux,
  app sandbox on macOS) and a multi-process model AWR does not have today.
  This is net-new security surface and net-new ops burden.
- **Fingerprint risk:** **high** if the boundary leaks. ADR 0003's own guard —
  "use it as a layout oracle first, not a browser replacement" — exists
  precisely so Chromium's network stack never touches the wire. Keeping that
  boundary narrow is a continuous maintenance obligation.
- **Maintenance estimate:** *low* engine maintenance (Google maintains
  Chromium) but *high* integration/version-churn + sandbox maintenance. CDP
  surface drifts; Chromium updates monthly.

### Path B — Servo / LibWeb component via IPC

- **Packaging:** lighter than Chromium but still a large C++/Rust component with
  its own build toolchain (Rust for Servo, C++ for LibWeb/Ladybird). Multi-
  language build; cross-compiling for AWR's eventual platforms is non-trivial.
- **Sandboxing:** less mature isolation story than Chromium; AWR would own more
  of the sandboxing itself.
- **Fingerprint risk:** medium — same "keep it layout-only" discipline needed.
- **Maintenance estimate:** *high* — smaller ecosystems, less predictable WPT
  parity (ADR 0003 Option B cons), AWR carries more integration glue and tracks
  a fast-moving upstream.

### Path C — native Zig layout engine

- **Packaging:** **best** — preserves the current footprint exactly (no new
  process, no new dylib, no sandbox). Stays macOS/arm64-shippable with the same
  toolchain; cross-platform later is the same story as the rest of AWR.
- **Sandboxing:** unchanged from today (no new attack surface).
- **Fingerprint risk:** **none** — no foreign network stack ever exists.
- **Maintenance estimate:** *highest engineering cost up front* (12-18
  person-months per `browser-roadmap.md §3`) and a *large permanent surface*
  (cascade — already done — plus box model, block/inline flow, text shaping,
  tables, flex, grid, scroll geometry, observers). But it is **AWR-team-owned,
  single-language, single-toolchain** maintenance with no upstream version
  churn and no sandbox ops.

## 4. Maintenance-burden summary

| Path | Up-front cost | Ongoing eng burden | Packaging burden | Sandbox burden | Fingerprint risk |
|---|---|---|---|---|---|
| A — Chromium/CDP oracle | Low-med (POC) | High (CDP/version churn) | **High** (~+150-200 MB or system dep) | **High** (multi-process sandbox) | **High** if boundary leaks |
| B — Servo/LibWeb | Med-high | High (multi-lang, upstream churn) | Med-high (extra toolchain) | Med | Med |
| C — native Zig | **High** (12-18 pm) | Med-high but **self-owned** | **None** | **None** | **None** |

## 5. Team-capacity note

`CLAUDE.md` and the spec set describe a small maintainer group ("AWR
maintainers", ADR 0003 Owners) that has already shipped a large Zig surface
(net stack, JS bridge, DOM, CSSOM cascade, TUI). The 12-18 person-month native
estimate is the dominant risk for Path C; conversely, Paths A/B trade that for
*permanent* integration/sandbox/packaging tax that a small team pays forever.
Neither is free; the choice is "one large bounded project" (C) vs "ongoing
integration tax + identity dilution" (A/B).

## Recommendation input (not a decision)

On packaging and resources alone, **Path C preserves AWR's identity and ops
posture best** (no new process, no sandbox, no fingerprint fragmentation, no
platform regression) at the cost of the largest up-front engineering bill —
while **Path A is the worst packaging/sandbox/fingerprint fit** despite being
the fastest to a layout result. This argues for the ADR 0003 sequencing:
introduce the adapter seam, use an external oracle only as a *throwaway POC* to
de-risk the contract, and reserve any *shipped* layout for a native-Zig
implementation if and only if the WPT/site demand (which this audit's companions
find to be small) justifies the up-front cost.
