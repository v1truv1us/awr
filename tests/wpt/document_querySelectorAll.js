test(() => {
  const items = document.querySelectorAll('li.item');
  assert_equals(items.length, 3);
  assert_equals(items[0].textContent, 'a');
}, 'document.querySelectorAll returns all matching elements');

test(() => {
  assert_equals(document.querySelectorAll('.missing').length, 0);
}, 'document.querySelectorAll returns an empty collection when nothing matches');
