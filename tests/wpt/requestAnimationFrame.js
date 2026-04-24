promise_test(async () => {
  let called = false;
  let stamp = null;

  await new Promise((resolve) => {
    requestAnimationFrame((ts) => {
      called = true;
      stamp = ts;
      resolve();
    });
  });

  assert_true(called);
  assert_true(typeof stamp === 'number');
}, 'requestAnimationFrame schedules a callback with a timestamp');
