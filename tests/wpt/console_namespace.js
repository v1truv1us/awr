test(() => {
  assert_equals(typeof console, 'object');
}, 'console namespace is present');

test(() => {
  assert_equals(typeof console.log, 'function');
  assert_equals(typeof console.warn, 'function');
  assert_equals(typeof console.error, 'function');
}, 'console namespace exposes log/warn/error methods');
