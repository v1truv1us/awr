test(() => {
  assert_equals(window, globalThis);
  assert_equals(typeof window.innerWidth, 'number');
  assert_equals(typeof window.innerHeight, 'number');
  assert_true(window.innerWidth > 0);
  assert_true(window.innerHeight > 0);
}, 'window aliases globalThis and exposes viewport dimensions');

test(() => {
  assert_equals(typeof screen, 'object');
  assert_equals(typeof screen.width, 'number');
  assert_equals(typeof screen.height, 'number');
  assert_equals(typeof devicePixelRatio, 'number');
}, 'screen and devicePixelRatio are wired');
