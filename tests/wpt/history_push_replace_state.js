test(() => {
  history.pushState({ page: 2 }, '', '/docs');
  assert_equals(history.length, 2);
  assert_equals(history.state.page, 2);
  assert_equals(location.pathname, '/docs');

  history.replaceState({ page: 3 }, '', '/docs/next');
  assert_equals(history.length, 2);
  assert_equals(history.state.page, 3);
  assert_equals(location.pathname, '/docs/next');
  assert_equals(typeof history.back, 'undefined');
  assert_equals(typeof history.forward, 'undefined');
  assert_equals(typeof history.go, 'undefined');
}, 'history exposes same-origin pushState/replaceState plus state and length');
