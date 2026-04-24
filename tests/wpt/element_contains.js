test(() => {
  const shell = document.getElementById('shell');
  const leaf = document.getElementById('leaf');
  assert_true(shell.contains(shell));
  assert_true(shell.contains(leaf));
  assert_false(leaf.contains(shell));
  assert_false(shell.contains(null));
}, 'contains reflects DOM ancestry and self containment');
