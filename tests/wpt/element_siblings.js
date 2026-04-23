test(() => {
  const second = document.getElementById('second');
  assert_not_equals(second, null);
  assert_equals(second.previousSibling.id, 'first');
  assert_equals(second.nextSibling.id, 'third');
}, 'element sibling getters traverse the parsed DOM tree');
