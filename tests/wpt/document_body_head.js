test(() => {
  assert_equals(document.body.tagName, 'BODY');
  assert_equals(document.head.tagName, 'HEAD');
  assert_equals(document.documentElement.tagName, 'HTML');
}, 'document exposes body, head, and documentElement');
