test(() => {
  const item = document.getElementById('item');
  assert_not_equals(item, null);
  assert_true(item.classList.contains('foo'));
  assert_true(item.classList.contains('bar'));

  item.classList.add('baz');
  assert_true(item.classList.contains('baz'));
  assert_equals(item.className, 'foo bar baz');
  assert_equals(item.getAttribute('class'), 'foo bar baz');

  item.classList.remove('foo');
  assert_false(item.classList.contains('foo'));
  assert_equals(item.className, 'bar baz');

  item.classList.toggle('qux');
  assert_true(item.classList.contains('qux'));
  item.classList.toggle('qux');
  assert_false(item.classList.contains('qux'));
  assert_equals(item.getAttribute('class'), 'bar baz');
}, 'classList stays live and synchronized with className and class attribute');
