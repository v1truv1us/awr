globalThis.__dom_loaded = false;
document.addEventListener('DOMContentLoaded', () => {
  globalThis.__dom_loaded = true;
});

promise_test(async () => {
  await Promise.resolve();
  assert_true(globalThis.__dom_loaded);
}, 'DOMContentLoaded fires after script registration');
