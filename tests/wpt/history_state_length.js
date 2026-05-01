test(() => {
  assert_equals(typeof history.length, 'number');
  assert_true(history.length >= 1);
  assert_equals(history.state, null);
}, 'history.length is at least 1 and initial history.state is null');

test(() => {
  const startLength = history.length;
  history.pushState({ step: 1 }, '', '/a');
  assert_equals(history.length, startLength + 1);
  assert_equals(history.state.step, 1);
  history.replaceState({ step: 2 }, '', '/a');
  assert_equals(history.length, startLength + 1);
  assert_equals(history.state.step, 2);
}, 'history.pushState grows length and replaceState updates state in place');
