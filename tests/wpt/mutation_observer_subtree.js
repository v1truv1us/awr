promise_test(async () => {
  const shell = document.getElementById('shell');
  const leaf = document.getElementById('leaf');
  let seen = [];
  const observer = new MutationObserver((records) => {
    seen = seen.concat(records);
  });

  observer.observe(shell, { attributes: true, subtree: true });
  leaf.setAttribute('data-state', 'ready');

  await Promise.resolve();
  assert_equals(seen.length, 1);
  assert_equals(seen[0].type, 'attributes');
  assert_equals(seen[0].target.id, 'leaf');
  assert_equals(seen[0].attributeName, 'data-state');
}, 'MutationObserver observes subtree attribute mutations');
