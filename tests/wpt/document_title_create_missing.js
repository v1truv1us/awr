test(() => {
  assert_equals(document.title, '');
  document.title = 'Created Title';
  assert_equals(document.title, 'Created Title');
  assert_equals(document.head.querySelector('title').textContent, 'Created Title');
}, 'setting document.title creates a title element when missing');
