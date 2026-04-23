test(() => {
  const leaf = document.getElementById('leaf');
  assert_not_equals(leaf, null);
  assert_equals(leaf.parentNode.id, 'shell');
  assert_equals(leaf.parentElement.id, 'shell');
}, 'element parentNode and parentElement reflect the parsed DOM tree');

test(() => {
  const shell = document.getElementById('shell');
  const created = document.createElement('span');
  created.id = 'dynamic';
  shell.appendChild(created);
  assert_equals(created.parentNode.id, 'shell');
  assert_true(shell.contains(created));
}, 'appendChild updates parent tracking and contains()');
