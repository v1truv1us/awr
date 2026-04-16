promise_test(async () => {
  const value = await Promise.resolve('ok');
  assert_equals(value, 'ok');
}, 'promise_test resolves async work');

promise_test(() => {
  return Promise.resolve().then(() => {
    assert_true(true);
  });
}, 'promise_test records pass after microtasks drain');
