test(() => {
  const el = document.getElementById('node');
  el.className = '';
  assert_equals(el.classList.toggle('foo'), true);
  assert_true(el.classList.contains('foo'));
  assert_equals(el.classList.toggle('foo'), false);
  assert_false(el.classList.contains('foo'));
}, 'classList.toggle returns true when adding and false when removing');
