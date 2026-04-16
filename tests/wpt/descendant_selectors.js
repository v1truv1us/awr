test(() => {
  const el = document.querySelector('section p');
  assert_equals(el && el.id, 'target');
}, 'document.querySelector supports descendant selectors');

test(() => {
  const ids = Array.from(document.querySelectorAll('section p')).map((el) => el.id);
  assert_array_equals(ids, ['target', 'other']);
}, 'document.querySelectorAll supports descendant selectors');
