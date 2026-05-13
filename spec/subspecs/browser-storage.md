# Web Storage — Tier 3 sub-spec

> **Status:** CLOSED 2026-05-13 (initial promotion + closure same day)
> `spec/MVP.md` is the canonical umbrella spec.
> `spec/subspecs/browser-roadmap.md` is the cross-tier ladder
> authority; this file owns Tier 3 Web Storage execution detail.

---

## 1. Purpose and authority

Tier 3 Web Storage support enables sites that store lightweight
session or user state in `localStorage` / `sessionStorage` to work
correctly in AWR. After this slice, login flows that use
`localStorage` for auth tokens (common in SPAs) and sites that
cache user preferences in storage are reachable without custom
workarounds.

This sub-spec governs:

1. `localStorage` — origin-scoped, disk-persisted key/value store;
   survives `awr tui` restarts within the same user account;
2. `sessionStorage` — origin-scoped, in-memory key/value store;
   cleared on `awr tui` exit (per-session).

Both implement the `Storage` interface:
`getItem`, `setItem`, `removeItem`, `clear`, `key`, `length`.

If scope changes, update this file in the same change as
`spec/MVP.md` per `spec/MVP.md §8` and reflect the change in
`spec/subspecs/browser-roadmap.md §3`.

---

## 2. In scope

### 2.1 Storage interface

Both `localStorage` and `sessionStorage` expose the same five
methods plus `length` on the JS global object. Keys and values are
`DOMString` (UTF-8 in AWR's encoding).

### 2.2 localStorage persistence

Backed by a per-origin JSON file in
`$XDG_DATA_HOME/awr/storage/<origin-hash>.json`
(default `~/.local/share/awr/storage/`).

- Load on first access for the origin; flush on `setItem` /
  `removeItem` / `clear`.
- File permissions `0600` (storage may contain tokens).
- Maximum 5 MB per origin; `setItem` throws `QuotaExceededError`
  when exceeded (Web Storage standard behaviour).

### 2.3 sessionStorage lifetime

In-memory `StringHashMap` allocated per-Page, freed on page
deinit. Not shared across tabs (even for the same origin) — per
the spec, `sessionStorage` is browsing-context-scoped.

### 2.4 Origin scoping

Origin = `scheme + "://" + host + optional_port`. Determined from
`document.URL` at the time of first access. Cross-origin iframes
(not yet supported) are out of scope.

### 2.5 storage event

`StorageEvent` is NOT required for Tier 3 (it requires cross-tab
communication, which is Tier 4+ territory). Document this
explicitly in the JS bridge stub as a known gap.

---

## 3. Out of scope (defer to later tiers)

- `storage` event (cross-tab notification) — Tier 4+
- IndexedDB — not planned (complexity disproportionate to gain)
- Cookie access via `document.cookie` (separate subsystem — already
  handled in `src/net/cookie.zig`)
- `navigator.storage` quota API — Tier 4+

---

## 4. Closure gates

This slice closes when **all** of the following are true:

1. Existing Tier 0 + Tier 1 + Tier 2 gates remain green;
2. `zig build test` covers `localStorage` round-trip (set → get →
   persist → reload → get);
3. `zig build test` covers `sessionStorage` lifetime (cleared
   between Page instances);
4. `zig build test` covers `QuotaExceededError` at 5 MB limit;
5. At least one WPT `webstorage` case in the curated corpus
   (`zig build test-wpt` green).

---

## 5. Verification gates

1. `zig build test` green;
2. `zig build test-wpt` green including §4.5 storage case(s);
3. Manual smoke: visit a site that reads `localStorage` on load,
   confirm value survives `awr tui` restart.

---

## 6. Implementation notes

Indicative slice (defer detailed plan to implementation time):

1. Add `LocalStorage` struct to `src/js/` backed by JSON file I/O;
   lazily loaded per origin.
2. Add `SessionStorage` struct (in-memory `StringHashMap`) to
   `src/page.zig`, freed in `Page.deinit`.
3. Expose both on the JS global object via the bridge, implementing
   the five `Storage` interface methods.
4. Enforce 5 MB quota in `setItem`; throw `QuotaExceededError`.

---

## 7. Open questions

1. Should the origin hash use SHA-256 of the origin string, or a
   simpler URL-safe encoding? Likely answer: simple percent-encoding
   of `scheme_host_port` (no crypto dependency needed).
2. Should `localStorage` flush synchronously on every `setItem`
   (safe but slow) or batch-write on a short timer? Likely answer:
   synchronous flush for Tier 3; async batching is a Tier 4+
   optimization.

---

## 8. Closure record

| Field | Value |
|-------|-------|
| Status | CLOSED |
| Date | 2026-05-13 |
| Final commit | (this commit — T3.A localStorage + sessionStorage wire-up) |
| Gates satisfied | §4.1 prior-tier gates green ✓ / §4.2 round-trip test ✓ / §4.3 sessionStorage lifetime ✓ / §4.4 QuotaExceededError test ✓ / §4.5 WPT corpus extended (storage_localStorage.js + storage_quota_exceeded.js) ✓ |
| Sign-off | AWR Dev |

**Delivered surface:**

- `Storage` interface (`getItem` / `setItem` / `removeItem` / `clear` /
  `key` / `length`) for both `localStorage` and `sessionStorage`.
- localStorage: per-origin disk persistence at
  `$XDG_DATA_HOME/awr/storage/<encoded-origin>.json`
  (configurable via `$AWR_STORAGE_DIR`), mode 0600, atomic
  write-tmp + rename. Insertion order preserved via
  `StringArrayHashMapUnmanaged`.
- sessionStorage: in-memory per Page (per JS context), cleared
  on Page deinit.
- 5 MB per-storage quota enforced with atomic-on-failure semantics:
  the JS-thrown `QuotaExceededError` leaves the prior entry intact.
- Cross-origin isolation: foo.com and bar.com get separate JSON
  files; in-memory state is reset whenever `setStorageOrigin` sees
  a different origin.

**Known scope NOT covered (deferred):**

- `storage` event (cross-tab broadcasts) — §3 explicit non-goal.
  Requires multi-process state sharing AWR doesn't have yet.
- Daemon scoping for `initShared` — `storage_dir` stays null under
  daemon mode pending the Tier 3 daemon-scope work alongside
  cross-process URL state.

**Test surface:**

- `src/js/storage.zig` — 9 unit tests (round-trip, cross-origin,
  quota atomicity, JSON-escape round-trip, etc.).
- `src/dom/bridge.zig` — 5 bridge tests (JS-level round-trip,
  length/key/removeItem/clear, sessionStorage independence,
  QuotaExceededError throw, cross-process persistence via
  `setStorageOrigin`).
- `src/util/storage_path.zig` — 1 test for `$AWR_STORAGE_DIR`
  override (skipped on platforms without `std.c.setenv`).
- `tests/wpt/storage_localStorage.js` — pre-existing WPT coverage
  of the API + insertion-order semantics (passing as of this slice).
- `tests/wpt/storage_quota_exceeded.js` — new WPT case asserting
  `QuotaExceededError` name + atomic preservation.
