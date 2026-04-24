promise_test(async () => {
  let called = false;
  const id = requestIdleCallback(() => { called = true; });
  cancelIdleCallback(id);
  await Promise.resolve();
  await Promise.resolve();
  assert_false(called);
}, 'cancelIdleCallback prevents the scheduled idle callback');
