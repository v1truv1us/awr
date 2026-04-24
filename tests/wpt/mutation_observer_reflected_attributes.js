promise_test(async () => {
  const target = document.getElementById('target');
  let seen = [];
  const observer = new MutationObserver((records) => {
    seen = seen.concat(records);
  });

  observer.observe(target, { attributes: true, attributeOldValue: true });
  target.id = 'renamed';
  target.className = 'primary accent';

  await Promise.resolve();
  assert_equals(seen.length, 2);
  assert_equals(seen[0].attributeName, 'id');
  assert_equals(seen[0].oldValue, 'target');
  assert_equals(seen[1].attributeName, 'class');
  assert_equals(seen[1].oldValue, null);
}, 'MutationObserver reports reflected id and className mutations');
