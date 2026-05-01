test(() => {
  const list = document.querySelectorAll('p');
  assert_equals(list.length, 3);
  const ids = [];
  list.forEach(el => ids.push(el.id));
  assert_array_equals(ids, ['a', 'b', 'c']);
}, 'querySelectorAll returns an array-like with length and forEach in document order');

test(() => {
  const list = document.querySelectorAll('p.match');
  assert_equals(list.length, 2);
  assert_equals(list[0].id, 'a');
  assert_equals(list[1].id, 'c');
}, 'querySelectorAll filters by compound selector');
