// KeyboardEvent — key, code, and modifier-key fields survive the
// constructor → dispatch → listener round-trip. T-87 / Tier 1 §4.2
// closure gate. Before this case landed, KeyboardEvent was aliased
// to Event and the init-dict fields were dropped.

test(() => {
  const ev = new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter' });
  assert_equals(ev.type, 'keydown');
  assert_equals(ev.key, 'Enter');
  assert_equals(ev.code, 'Enter');
  // Modifier defaults.
  assert_equals(ev.altKey, false);
  assert_equals(ev.ctrlKey, false);
  assert_equals(ev.shiftKey, false);
  assert_equals(ev.metaKey, false);
  assert_equals(ev.repeat, false);
}, 'KeyboardEvent constructor preserves key + code from init dict');

test(() => {
  const ev = new KeyboardEvent('keyup', {
    key: 'a',
    code: 'KeyA',
    altKey: true,
    ctrlKey: true,
    shiftKey: true,
    metaKey: false,
    repeat: true,
  });
  assert_equals(ev.type, 'keyup');
  assert_equals(ev.key, 'a');
  assert_equals(ev.code, 'KeyA');
  assert_equals(ev.altKey, true);
  assert_equals(ev.ctrlKey, true);
  assert_equals(ev.shiftKey, true);
  assert_equals(ev.metaKey, false);
  assert_equals(ev.repeat, true);
}, 'KeyboardEvent preserves all modifier flags + repeat from init dict');

test(() => {
  // which/keyCode/charCode legacy fields.
  const ev = new KeyboardEvent('keydown', { key: 'A', code: 'KeyA', which: 65 });
  assert_equals(ev.which, 65);
  // keyCode falls back to `which` when not explicitly given.
  assert_equals(ev.keyCode, 65);
  assert_equals(ev.charCode, 0);
}, 'KeyboardEvent legacy which/keyCode/charCode fields');

test(() => {
  // Listeners observe the dispatched event with its fields intact.
  const t = document.getElementById('t');
  let seen_key = null;
  let seen_code = null;
  let seen_shift = null;
  t.addEventListener('keydown', (e) => {
    seen_key = e.key;
    seen_code = e.code;
    seen_shift = e.shiftKey;
  });
  t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', code: 'Tab', shiftKey: true, bubbles: true }));
  assert_equals(seen_key, 'Tab');
  assert_equals(seen_code, 'Tab');
  assert_equals(seen_shift, true);
}, 'dispatched KeyboardEvent reaches listeners with key/code/shift preserved');

test(() => {
  // KeyboardEvent inherits Event prototype: cancelable + preventDefault path.
  const ev = new KeyboardEvent('keydown', { key: 'Enter', cancelable: true });
  assert_equals(ev.defaultPrevented, false);
  ev.preventDefault();
  assert_equals(ev.defaultPrevented, true);
}, 'KeyboardEvent inherits preventDefault behavior from Event');
