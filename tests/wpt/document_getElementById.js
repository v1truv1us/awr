test(() => {
  const el = document.getElementById('main');
  assert_not_equals(el, null);
  assert_equals(el.textContent, 'primary');
}, 'document.getElementById finds an existing element');

test(() => {
  assert_equals(document.getElementById('missing'), null);
}, 'document.getElementById returns null for a missing id');
