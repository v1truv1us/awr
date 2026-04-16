test(() => {
  const link = document.getElementById('link');
  assert_equals(link.getAttribute('href'), '/docs');
  assert_equals(link.getAttribute('data-kind'), 'primary');
}, 'element.getAttribute returns attribute values');

test(() => {
  const copy = document.getElementById('copy');
  assert_equals(copy.textContent, 'alphabeta');
}, 'element.textContent concatenates descendant text');
