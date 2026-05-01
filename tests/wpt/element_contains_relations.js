test(() => {
  const root = document.getElementById('root');
  assert_true(root.contains(root));
}, 'contains(self) is true');

test(() => {
  const root = document.getElementById('root');
  const leaf = document.getElementById('leaf');
  const sibling = document.getElementById('sibling');
  assert_true(root.contains(leaf));
  assert_false(leaf.contains(root));
  assert_false(root.contains(sibling));
}, 'contains reflects ancestor / descendant relationships');
