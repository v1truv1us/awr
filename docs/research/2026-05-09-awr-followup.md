# AWR Follow-up — 2026-05-09

## Scope

Read-only follow-up on recent `pi-awr-web` problem-log entries and whether the main reported hang is still present in the local AWR checkout.

Sources reviewed:

- `~/.pi/agent/awr-web/problems.jsonl`
- `src/page.zig`
- `src/js/event_loop.zig`
- local git history in `/Users/johnferguson/Github/awr`

## Problem-log triage

Entries reviewed:

- `awr-20260508000623-lie701` — `https://example.com`
- `awr-20260508004821-nwnk51` — nonexistent-domain DNS failure
- `awr-20260508013044-vc7arx` — manual reminder note
- `awr-20260508021000-drain_hang` — `drainAll()` hang note for `react.dev`

### Assessment

- `awr-20260508000623-lie701` is not a strong current engine bug signal. Earlier session notes already classified it as a false positive / binary-resolution issue.
- `awr-20260508004821-nwnk51` is expected DNS failure for a fake domain, not an AWR bug.
- `awr-20260508013044-vc7arx` is a reminder, not a bug record.
- `awr-20260508021000-drain_hang` was the only real bug candidate.

## Code check

The old hang path appears fixed in the current repository state.

### Fix present in source

`src/page.zig` now bounds `drainAll()` by wall-clock deadline and calls:

- `self.event_loop.tickOnceWithTimeout(remaining_ms)`

`src/js/event_loop.zig` now implements `tickOnceWithTimeout()` by:

- arming a one-shot deadline timer
- calling `loop.run(.once)`
- canceling the deadline timer on real-event wake
- draining cleanup with `loop.run(.no_wait)`

### Regression coverage present

`src/js/event_loop.zig` includes tests for:

- long-delay timer returns within budget
- fast timer fires before the timeout budget expires

### Git history

Relevant commit in local checkout:

- `fb1f2f5 fix(js): deadline-bounded tickOnce so drainAll honors max_ms`

That commit message explicitly references the prior `react.dev` behavior and documents the bounded-wait fix.

## Runtime verification

### 1. `react.dev`

Command:

```bash
AWR_TIMING=1 /Users/johnferguson/Github/awr/zig-out/bin/awr https://react.dev
```

Observed:

- exit status: `0`
- elapsed: `4.138s`
- title: `React`
- timing markers included:
  - `scripts=251ms`
  - `drain_interactive=1002ms`
  - `drain_load=2002ms`
  - `total=3746ms`

Conclusion:

- the previous hang signature is **not** present
- `drain_interactive` now completes and the page returns usable content

### 2. `x.com`

Command:

```bash
AWR_TIMING=1 /Users/johnferguson/Github/awr/zig-out/bin/awr https://x.com
```

Observed:

- exit status: `0`
- elapsed: `2.395s`
- status: `200`
- body content is a challenge / failure page:
  - `Something went wrong, but don’t fret — let’s give it another shot.`

Conclusion:

- not a hang
- not a crash
- likely challenge / anti-bot / browser-fingerprint behavior rather than the old `drainAll()` bug

### 3. `reddit.com/r/programming`

Command:

```bash
AWR_TIMING=1 /Users/johnferguson/Github/awr/zig-out/bin/awr https://www.reddit.com/r/programming
```

Observed:

- exit status: `0`
- elapsed: `0.455s`
- status: `200`
- title: `Reddit - Please wait for verification`
- body text is effectively empty / challenge-page output

Conclusion:

- not a hang
- not a crash
- likely challenge / verification behavior rather than the old `drainAll()` bug

## Final conclusion

### Closed / fixed

The `awr-20260508021000-drain_hang` investigation should be treated as fixed in the current local AWR checkout.

### Still worth tracking separately

AWR can still return challenge / verification content for sites like:

- `x.com`
- `reddit.com`

That should be tracked, if needed, as a separate content-access / anti-bot / fingerprinting limitation, not as the old event-loop hang.

## Suggested next step if this becomes repo work

If we want a new tracked item, keep it separate from the fixed `drainAll()` timeout issue.

Suggested issue title:

- `bot-protected sites can return challenge pages instead of usable content`

Suggested scope:

- `x.com` returns a challenge/failure page instead of usable content
- `reddit.com/r/programming` returns a verification page instead of usable content
- this is a content-access / anti-bot / browser-identity limitation, not an event-loop hang regression
