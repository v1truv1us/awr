test(() => {
  const host = document.getElementById('host');
  const child = document.createElement('div');
  child.id = 'dynamic';
  host.appendChild(child);
  const found = document.getElementById('dynamic');
  assert_not_equals(found, null);
  assert_equals(found.id, 'dynamic');
}, 'getElementById finds dynamically appended elements');
