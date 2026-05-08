// Element interaction events — input, change, focus, blur, keydown, keyup.
// Verifies the dispatch path the spec calls out for form controls and
// keyboard handlers.

test(() => {
  const t = document.getElementById('t');
  let count = 0;
  t.addEventListener('input', () => { count += 1; });
  t.dispatchEvent(new Event('input', { bubbles: true }));
  assert_equals(count, 1);
}, 'input event listener fires on dispatch');

test(() => {
  const s = document.getElementById('s');
  let count = 0;
  s.addEventListener('change', () => { count += 1; });
  s.dispatchEvent(new Event('change', { bubbles: true }));
  assert_equals(count, 1);
}, 'change event listener fires on dispatch');

test(() => {
  // change event from .onchange property
  const cb = document.getElementById('cb');
  let fired = false;
  cb.onchange = () => { fired = true; };
  cb.dispatchEvent(new Event('change', { bubbles: true }));
  assert_true(fired);
}, 'change event fires through onchange property (DOM Level-0)');

test(() => {
  const t = document.getElementById('t');
  let fcount = 0;
  let bcount = 0;
  t.addEventListener('focus', () => { fcount += 1; });
  t.addEventListener('blur', () => { bcount += 1; });
  t.focus();
  t.blur();
  assert_equals(fcount, 1);
  assert_equals(bcount, 1);
}, 'element.focus() and element.blur() dispatch focus/blur events');

test(() => {
  // KeyboardEvent constructor (aliased to Event in AWR — type/bubbles work,
  // but key/code/charCode are not preserved; this matches the shape that
  // event_constructors_alias.js already documents).
  const k = new KeyboardEvent('keydown');
  assert_equals(k.type, 'keydown');
  assert_equals(k.bubbles, false);
  // Listener wires up like any other event.
  let fired = null;
  document.addEventListener('keydown', (e) => { fired = e.type; });
  document.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true }));
  assert_equals(fired, 'keydown');
}, 'KeyboardEvent dispatches and listener observes type');

test(() => {
  // Bubble ordering: input event fired on a child should reach a listener
  // on the parent form via bubbling.
  const t = document.getElementById('t');
  const f = document.getElementById('f');
  let parent_fired = false;
  f.addEventListener('input', () => { parent_fired = true; });
  t.dispatchEvent(new Event('input', { bubbles: true }));
  assert_true(parent_fired);
}, 'input event bubbles up to parent form listener');

test(() => {
  // capture phase listener runs before bubble
  const t = document.getElementById('t');
  const f = document.getElementById('f');
  const order = [];
  f.addEventListener('input', () => order.push('capture'), true);
  t.addEventListener('input', () => order.push('target'));
  t.dispatchEvent(new Event('input', { bubbles: true }));
  // capture phase on parent first, then target phase on the input.
  assert_equals(order.length, 2);
  assert_equals(order[0], 'capture');
  assert_equals(order[1], 'target');
}, 'capture-phase listener runs before target listener');
