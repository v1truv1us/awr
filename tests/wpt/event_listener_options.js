test(() => {
  const el = document.getElementById('node');
  let count = 0;
  const cb = () => count += 1;
  el.addEventListener('probe', cb);
  el.dispatchEvent(new Event('probe'));
  el.removeEventListener('probe', cb);
  el.dispatchEvent(new Event('probe'));
  assert_equals(count, 1);
}, 'removeEventListener detaches the registered callback');

test(() => {
  const el = document.getElementById('node');
  let count = 0;
  el.addEventListener('once-probe', () => count += 1, { once: true });
  el.dispatchEvent(new Event('once-probe'));
  el.dispatchEvent(new Event('once-probe'));
  assert_equals(count, 1);
}, 'addEventListener once option auto-removes after first invocation');

test(() => {
  const el = document.getElementById('node');
  const cb = () => {};
  el.addEventListener('dup', cb);
  el.addEventListener('dup', cb);
  let count = 0;
  el.addEventListener('dup', () => count += 1);
  el.dispatchEvent(new Event('dup'));
  assert_equals(count, 1);
}, 'duplicate addEventListener registrations of the same callback collapse');
