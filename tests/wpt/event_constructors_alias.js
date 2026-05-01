test(() => {
  const m = new MouseEvent('click', { bubbles: true });
  assert_equals(m.type, 'click');
  assert_equals(m.bubbles, true);
}, 'MouseEvent constructor accepts type and option bag');

test(() => {
  const k = new KeyboardEvent('keydown');
  assert_equals(k.type, 'keydown');
  assert_equals(k.bubbles, false);
}, 'KeyboardEvent constructor accepts type only');

test(() => {
  const c = new CustomEvent('ready', { detail: { ok: true }, bubbles: true });
  assert_equals(c.type, 'ready');
  assert_equals(c.bubbles, true);
  assert_equals(c.detail.ok, true);
  assert_true(c instanceof Event);
}, 'CustomEvent inherits from Event and exposes detail');
