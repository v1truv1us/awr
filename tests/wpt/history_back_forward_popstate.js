test(() => {
  // Push two states past the initial entry, then traverse with
  // back() / forward() and verify popstate fires with the new state.
  const startLength = history.length;
  history.pushState({ step: 1 }, '', '/step/1');
  history.pushState({ step: 2 }, '', '/step/2');
  assert_equals(history.length, startLength + 2);
  assert_equals(history.state.step, 2);

  let lastPopState = undefined;
  function onPop(e) { lastPopState = e.state; }
  window.addEventListener('popstate', onPop);

  history.back();
  assert_equals(location.pathname, '/step/1');
  assert_equals(history.state.step, 1);
  assert_true(lastPopState !== undefined, 'popstate must fire on back()');
  assert_equals(lastPopState.step, 1);

  history.forward();
  assert_equals(location.pathname, '/step/2');
  assert_equals(history.state.step, 2);
  assert_equals(lastPopState.step, 2);

  // pushState after back() truncates forward history.
  history.back(); // back to /step/1
  history.pushState({ step: 99 }, '', '/step/99');
  assert_equals(history.length, startLength + 2);
  assert_equals(history.state.step, 99);
  // forward() now does nothing (no forward history).
  history.forward();
  assert_equals(location.pathname, '/step/99');

  window.removeEventListener('popstate', onPop);
}, 'history.back / forward / go traverse the stack and fire popstate');

test(() => {
  // go(0) is a no-op (no reload concept in AWR). Out-of-range
  // go(N) does nothing (cursor stays put, no popstate).
  let popstateCount = 0;
  function onPop() { popstateCount += 1; }
  window.addEventListener('popstate', onPop);

  history.pushState({ a: 1 }, '', '/x');
  const url = location.pathname;
  history.go(0);
  assert_equals(location.pathname, url, 'go(0) must not navigate');
  history.go(99);
  assert_equals(location.pathname, url, 'out-of-range go must not navigate');
  history.go(-99);
  assert_equals(location.pathname, url, 'out-of-range back must not navigate');
  assert_equals(popstateCount, 0, 'no popstate when cursor did not move');

  window.removeEventListener('popstate', onPop);
}, 'history.go(0) is a no-op and out-of-range go does not fire popstate');
