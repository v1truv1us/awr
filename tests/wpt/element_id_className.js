test(() => {
  const node = document.getElementById('node');
  node.id = 'updated';
  node.className = 'one two';
  assert_equals(node.id, 'updated');
  assert_equals(node.getAttribute('id'), 'updated');
  assert_equals(node.className, 'one two');
  assert_equals(node.getAttribute('class'), 'one two');
}, 'id and className setters stay synchronized with attributes');
