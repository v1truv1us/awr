test(() => {
  const e = new Event('foo');
  assert_equals(e.type, 'foo');
  assert_equals(e.bubbles, false);
  assert_equals(e.cancelable, false);
  assert_equals(e.defaultPrevented, false);
  assert_equals(e.target, null);
  assert_equals(e.currentTarget, null);
  assert_equals(e.eventPhase, 0);
}, 'Event constructor sets default property values');

test(() => {
  const e = new Event('foo', { bubbles: true, cancelable: true });
  assert_equals(e.bubbles, true);
  assert_equals(e.cancelable, true);
  e.preventDefault();
  assert_equals(e.defaultPrevented, true);
}, 'Event respects bubbles/cancelable options and preventDefault');

test(() => {
  const e = new Event('foo', { cancelable: false });
  e.preventDefault();
  assert_equals(e.defaultPrevented, false);
}, 'preventDefault is a no-op on a non-cancelable Event');
