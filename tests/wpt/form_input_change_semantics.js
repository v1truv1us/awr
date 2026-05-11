// Form input event semantics — `input` and `change` event timing,
// ordering, and reach. Sister test to element_interaction_events.js
// which covers the dispatch path. T-87 / Tier 1 §4.2 closure gate.

test(() => {
  // Setting input.value from JS does NOT fire the `input` event
  // per spec (the event is for user-input edits). Listeners only
  // fire when something explicitly dispatches.
  const inp = document.getElementById('t');
  let fired = false;
  inp.addEventListener('input', () => { fired = true; });
  inp.value = 'changed';
  assert_equals(fired, false, 'value assignment does not auto-fire input event');
}, 'setting input.value from JS does not dispatch input event');

test(() => {
  // Explicit dispatch — the path a TUI/test would use to simulate
  // a user keystroke — DOES reach listeners.
  const inp = document.getElementById('t');
  let count = 0;
  inp.addEventListener('input', () => { count += 1; });
  inp.dispatchEvent(new Event('input', { bubbles: true }));
  inp.dispatchEvent(new Event('input', { bubbles: true }));
  assert_equals(count, 2, 'each dispatch hits the listener exactly once');
}, 'dispatched input events reach listeners deterministically');

test(() => {
  // Spec: input event always bubbles. Listener on the form catches
  // it without needing to attach to every child input.
  const form = document.getElementById('f');
  const inp = document.getElementById('t');
  let parent_count = 0;
  form.addEventListener('input', () => { parent_count += 1; });
  inp.dispatchEvent(new Event('input', { bubbles: true }));
  assert_equals(parent_count, 1, 'form catches bubbled input from child');
}, 'input event bubbles from input to ancestor form');

test(() => {
  // Multiple listeners on the same target — all fire in registration
  // order. This is the contract WPT-style listener chains rely on.
  const inp = document.getElementById('t');
  const order = [];
  inp.addEventListener('input', () => order.push('a'));
  inp.addEventListener('input', () => order.push('b'));
  inp.addEventListener('input', () => order.push('c'));
  inp.dispatchEvent(new Event('input', { bubbles: true }));
  assert_array_equals(order, ['a', 'b', 'c']);
}, 'multiple input listeners fire in registration order');

test(() => {
  // change event for checkbox: dispatched explicitly. Real browsers
  // also fire it when the user toggles via UI, but that's a TUI
  // concern (T-81 handles the click→change path internally).
  const cb = document.getElementById('cb');
  let observed_checked = null;
  cb.addEventListener('change', () => { observed_checked = cb.checked; });
  cb.checked = true;
  cb.dispatchEvent(new Event('change', { bubbles: true }));
  assert_equals(observed_checked, true);
}, 'change listener observes current checked state at dispatch time');

test(() => {
  // The select element fires change too, with the latest value.
  const s = document.getElementById('s');
  let observed_value = null;
  s.addEventListener('change', () => { observed_value = s.value; });
  s.value = 'b';
  s.dispatchEvent(new Event('change', { bubbles: true }));
  assert_equals(observed_value, 'b');
}, 'change listener on select observes the post-change value');

test(() => {
  // Cross-listener interaction: stopPropagation on an inner listener
  // stops the bubble. Form-level listener should NOT see the event.
  const inp = document.getElementById('t');
  const form = document.getElementById('f');
  let parent_fired = false;
  inp.addEventListener('input', (e) => { e.stopPropagation(); });
  form.addEventListener('input', () => { parent_fired = true; });
  inp.dispatchEvent(new Event('input', { bubbles: true }));
  assert_equals(parent_fired, false, 'stopPropagation blocks the form listener');
}, 'stopPropagation prevents input event from bubbling further');
