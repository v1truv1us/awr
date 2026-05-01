test(() => {
  const root = document.documentElement;
  assert_not_equals(root, null);
  assert_equals(root.tagName, 'HTML');
}, 'document.documentElement returns the <html> root');

test(() => {
  assert_equals(document.nodeType, 9);
  assert_equals(document.body.nodeType, 1);
  assert_equals(document.documentElement.nodeType, 1);
}, 'document and elements expose spec-correct nodeType values');
