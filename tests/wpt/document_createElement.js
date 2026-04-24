test(() => {
  const node = document.createElement('section');
  assert_equals(node.tagName, 'SECTION');
  assert_equals(node.nodeType, 1);
}, 'document.createElement creates an element node');
