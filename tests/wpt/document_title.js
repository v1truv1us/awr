test(() => {
  assert_equals(document.title, 'Harness Title');
}, 'document.title returns the head title text');

test(() => {
  assert_equals(document.querySelector('title').textContent, 'Harness Title');
}, 'title element text matches document.title');
