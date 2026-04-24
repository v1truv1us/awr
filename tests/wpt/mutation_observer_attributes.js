promise_test(async () => {
  const target = document.getElementById('target');
  let seen = [];
  const observer = new MutationObserver((records) => {
    seen = seen.concat(records);
  });

  observer.observe(target, { attributes: true, attributeOldValue: true });
  target.setAttribute('data-kind', 'primary');

  await Promise.resolve();
  assert_equals(seen.length, 1);
  assert_equals(seen[0].type, 'attributes');
  assert_equals(seen[0].target.id, 'target');
  assert_equals(seen[0].attributeName, 'data-kind');
  assert_equals(seen[0].oldValue, null);
}, 'MutationObserver reports attribute mutations with oldValue');
