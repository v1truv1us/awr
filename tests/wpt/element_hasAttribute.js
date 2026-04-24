test(() => {
  const node = document.getElementById('node');
  assert_true(node.hasAttribute('data-kind'));
  assert_equals(node.getAttribute('data-kind'), 'primary');
  node.removeAttribute('data-kind');
  assert_false(node.hasAttribute('data-kind'));
}, 'hasAttribute tracks set and removed attributes');
