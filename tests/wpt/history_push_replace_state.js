test(() => {
  history.pushState({ page: 2 }, '', '/docs');
  assert_equals(history.length, 2);
  assert_equals(history.state.page, 2);
  assert_equals(location.pathname, '/docs');

  history.replaceState({ page: 3 }, '', '/docs/next');
  assert_equals(history.length, 2);
  assert_equals(history.state.page, 3);
  assert_equals(location.pathname, '/docs/next');
  // T3.B: back/forward/go are now functions (were undefined before).
  assert_equals(typeof history.back, 'function');
  assert_equals(typeof history.forward, 'function');
  assert_equals(typeof history.go, 'function');
}, 'history exposes same-origin pushState/replaceState plus state and length');
