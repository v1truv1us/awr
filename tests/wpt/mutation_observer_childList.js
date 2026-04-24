promise_test(async () => {
  const target = document.getElementById('target');
  let seen = [];
  const observer = new MutationObserver((records) => {
    seen = seen.concat(records);
  });

  observer.observe(target, { childList: true });
  const child = document.createElement('span');
  child.id = 'added';
  target.appendChild(child);

  await Promise.resolve();
  assert_equals(seen.length, 1);
  assert_equals(seen[0].type, 'childList');
  assert_equals(seen[0].target.id, 'target');
  assert_equals(seen[0].addedNodes.length, 1);
  assert_equals(seen[0].addedNodes[0].id, 'added');
}, 'MutationObserver reports childList appendChild mutations');
