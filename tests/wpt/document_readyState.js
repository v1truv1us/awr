test(() => {
  assert_equals(document.readyState, 'loading');
}, 'document.readyState is loading during script execution');

promise_test(async () => {
  await new Promise((resolve) => window.addEventListener('load', resolve, { once: true }));
  assert_equals(document.readyState, 'complete');
}, 'document.readyState is complete after lifecycle completion');
