promise_test(async () => {
  let called = false;
  let remaining = null;
  await new Promise((resolve) => {
    requestIdleCallback((deadline) => {
      called = true;
      remaining = deadline.timeRemaining();
      resolve();
    });
  });
  assert_true(called);
  assert_true(typeof remaining === 'number');
}, 'requestIdleCallback schedules a callback with a deadline object');
